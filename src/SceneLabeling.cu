/*
 ============================================================================
 Name        : scenelabeling.cu
 Author      : liujinhang @ whut
 Version     :
 Copyright   : Your copyright notice
 Description : CUDA compute reciprocals
 ============================================================================
 */

#include <iostream>
#include <sstream>
#include <numeric>
#include <stdlib.h>
#include <cuda_runtime.h>
#include <cudnn.h>
#include <cublas_v2.h>
#include <FreeImage.h>
#include <unistd.h>
#include <string.h>
#include <algorithm>

#include "CuNeuralNetwork.h"
#include "ImageProcessor.h"
#include "KernelGenerator.h"
#include "Utility.h"
#include "TestCase.h"

#include <vector>

//////////////////////////////////////////////////////////////////////////////
// Error handling
// Adapted from the CUDNN classification code
// sample: https://developer.nvidia.com/cuDNN

#define FatalError(s) do {                                             \
    std::stringstream _where, _message;                                \
    _where << __FILE__ << ':' << __LINE__;                             \
    _message << std::string(s) + "\n" << __FILE__ << ':' << __LINE__;  \
    std::cerr << _message.str() << "\nAborting...\n";                  \
    cudaDeviceReset();                                                 \
    exit(1);                                                           \
} while(0)

#define checkCUDNN(status) do {                                        \
    std::stringstream _error;                                          \
    if (status != CUDNN_STATUS_SUCCESS) {                              \
      _error << "CUDNN failure: " << cudnnGetErrorString(status);      \
      FatalError(_error.str());                                        \
    }                                                                  \
} while(0)

#define checkCudaErrors(status) do {                                   \
    std::stringstream _error;                                          \
    if (status != 0) {                                                 \
      _error << "Cuda failure: " << status;                            \
      FatalError(_error.str());                                        \
    }                                                                  \
} while(0)

class SceneLabeling {
public:
	float * convolution_maxpooling_sigmoid(cudnnHandle_t cudnnHandle,
			float * h_input_data, int batchSize, int imageHeight,
			int imageWidth, int kernelHeight, int kernelWidth,
			int poolingWindowHeight, int poolingWindowWidth,
			int inputFeaturemaps, int outputFeaturemaps) {

		//卷积核初始化
		KernelGenerator generator;

		float * h_kernel;
		std::vector<float> kernel(kernelHeight * kernelWidth);
		generator.initializeKernelUsingXavierAlgorithm(kernelHeight,
				kernelWidth, outputFeaturemaps, &kernel);
		h_kernel = Utility::VectorToArray(&kernel);

		//偏置项初始化
		//与卷积核生成采用同样的方法同样的数量
		float * h_bias;
		std::vector<float> bias(outputFeaturemaps);
		generator.initializeBiasUsingXavierAlgorithm(outputFeaturemaps, &bias);
		h_bias = Utility::VectorToArray(&bias);

		//神经网络初始化
		CuNeuralNetwork network;

		//输入数据设定
		cudnnTensorDescriptor_t inputDataTensorDescriptor;
		float * d_data = network.createInputDataLayer(h_input_data,
				&inputDataTensorDescriptor, batchSize, inputFeaturemaps,
				imageHeight, imageWidth);

		//卷积核设定
		cudnnFilterDescriptor_t kernelDescriptor;
		float * d_kernel = network.createKernel(h_kernel, &kernelDescriptor,
				inputFeaturemaps, outputFeaturemaps, kernelHeight, kernelWidth);

		//卷积操作设定
		cudnnConvolutionDescriptor_t convolutionDescriptor;
		checkCUDNN(cudnnCreateConvolutionDescriptor(&convolutionDescriptor));
		//零填充的行数与列数：0,卷积的水平和垂直的滑动长度：1,x，y向上取样的比例尺：1
		//不使用卷积操作，因为卷积操作要旋转卷积核，而这里不需要旋转，互相关就是无需旋转的卷积乘法。
		checkCUDNN(
				cudnnSetConvolution2dDescriptor(convolutionDescriptor, 0, 0, 1,
						1, 1, 1, CUDNN_CROSS_CORRELATION));

		//输出数据设定
		cudnnTensorDescriptor_t outputDataTensorDescriptor;
		OutputDim outputDim;
		float *d_output_data = network.createOutputDataLayer(
				&inputDataTensorDescriptor, &kernelDescriptor,
				&convolutionDescriptor, &outputDataTensorDescriptor,
				&outputDim);

		//选择FP算法
		cudnnConvolutionFwdAlgo_t algorithm;
		checkCUDNN(
				cudnnGetConvolutionForwardAlgorithm(cudnnHandle,
						inputDataTensorDescriptor, kernelDescriptor,
						convolutionDescriptor, outputDataTensorDescriptor,
						CUDNN_CONVOLUTION_FWD_PREFER_FASTEST, 0, &algorithm));

		//设置workspace的大小
		size_t workspaceSizeInByte = 0;
		checkCUDNN(
				cudnnGetConvolutionForwardWorkspaceSize(cudnnHandle,
						inputDataTensorDescriptor, kernelDescriptor,
						convolutionDescriptor, outputDataTensorDescriptor,
						algorithm, &workspaceSizeInByte));

		void *d_cudnn_workspace = nullptr;
		checkCudaErrors(cudaMalloc(&d_cudnn_workspace, workspaceSizeInByte));

		//卷积运算
		float alpha = 1.0f, beta = 0.0f;
		checkCUDNN(
				cudnnConvolutionForward(cudnnHandle, &alpha,
						inputDataTensorDescriptor, d_data, kernelDescriptor,
						d_kernel, convolutionDescriptor, algorithm,
						d_cudnn_workspace, workspaceSizeInByte, &beta,
						outputDataTensorDescriptor, d_output_data));

		checkCudaErrors(cudaDeviceSynchronize());

		//偏置项设定
		cudnnTensorDescriptor_t biasTensorDescriptor;
		float *d_bias = network.addBiasUnits(h_bias, &biasTensorDescriptor,
				outputFeaturemaps, kernelHeight, kernelWidth);

		//加上偏置项
		alpha = 1.0f, beta = 1.0f;
		checkCUDNN(
				cudnnAddTensor(cudnnHandle, CUDNN_ADD_SAME_C, &alpha,
						biasTensorDescriptor, d_bias, &beta,
						outputDataTensorDescriptor, d_output_data));

		checkCudaErrors(cudaDeviceSynchronize());

		//池化设定
		alpha = 1.0f, beta = 0.0f;
		cudnnPoolingDescriptor_t poolingDescriptor;
		cudnnTensorDescriptor_t poolingDataTensorDescriptor;
		OutputDim poolingOutputDim;
		int poolingVerticalStride = 1;
		int poolingHorizontalStride = 1;
		float * d_pooling_output_data = network.createPoolingLayer(
				d_output_data, &outputDataTensorDescriptor, &poolingDescriptor,
				&poolingDataTensorDescriptor, &outputDim, poolingWindowHeight,
				poolingWindowWidth, poolingVerticalStride,
				poolingHorizontalStride, &poolingOutputDim);

		//池化运算
		checkCUDNN(
				cudnnPoolingForward(cudnnHandle, poolingDescriptor, &alpha,
						outputDataTensorDescriptor, d_output_data, &beta,
						poolingDataTensorDescriptor, d_pooling_output_data));

		checkCudaErrors(cudaDeviceSynchronize());

		//激活函数设定
		alpha = 1.0f, beta = 0.0f;
		float * d_activation_output_data;

		checkCudaErrors(
				cudaMalloc(&d_activation_output_data,
						sizeof(float) * poolingOutputDim.outputImages
								* poolingOutputDim.outputFeaturemapsForEachImage
								* poolingOutputDim.outputFeaturemapHeight
								* poolingOutputDim.outputFeaturemapWidth));

		checkCUDNN(
				cudnnActivationForward(cudnnHandle, CUDNN_ACTIVATION_SIGMOID,
						&alpha, poolingDataTensorDescriptor,
						d_pooling_output_data, &beta,
						poolingDataTensorDescriptor, d_activation_output_data));

		checkCudaErrors(cudaDeviceSynchronize());

		//Test section
		//d_output_data数据回传
		float * h_output_data = new float[outputDim.outputImages
				* outputDim.outputFeaturemapsForEachImage
				* outputDim.outputFeaturemapHeight
				* outputDim.outputFeaturemapWidth];
		checkCudaErrors(
				cudaMemcpyAsync(h_output_data, d_output_data,
						sizeof(float) * outputDim.outputImages
								* outputDim.outputFeaturemapsForEachImage
								* outputDim.outputFeaturemapHeight
								* outputDim.outputFeaturemapWidth,
						cudaMemcpyDeviceToHost));

		//d_pooling_output_data数据回传
		float * h_pooling_output_data = new float[poolingOutputDim.outputImages
				* poolingOutputDim.outputFeaturemapsForEachImage
				* poolingOutputDim.outputFeaturemapHeight
				* poolingOutputDim.outputFeaturemapWidth];
		checkCudaErrors(
				cudaMemcpyAsync(h_pooling_output_data, d_pooling_output_data,
						sizeof(float) * poolingOutputDim.outputImages
								* poolingOutputDim.outputFeaturemapsForEachImage
								* poolingOutputDim.outputFeaturemapHeight
								* poolingOutputDim.outputFeaturemapWidth,
						cudaMemcpyDeviceToHost));

		//d_activation_output_data数据回传
		float * h_activation_output_data =
				new float[poolingOutputDim.outputImages
						* poolingOutputDim.outputFeaturemapsForEachImage
						* poolingOutputDim.outputFeaturemapHeight
						* poolingOutputDim.outputFeaturemapWidth];
		checkCudaErrors(
				cudaMemcpyAsync(h_activation_output_data,
						d_activation_output_data,
						sizeof(float) * poolingOutputDim.outputImages
								* poolingOutputDim.outputFeaturemapsForEachImage
								* poolingOutputDim.outputFeaturemapHeight
								* poolingOutputDim.outputFeaturemapWidth,
						cudaMemcpyDeviceToHost));

		//测试用例：卷积运算测试
		TestCase::TestbedOfConvolutionMethodForOneOutputFeaturemap(h_input_data, h_output_data,
				h_kernel, h_bias[0], imageHeight, imageWidth, kernelHeight,
				kernelWidth);

		//Destroy section
		checkCUDNN(cudnnDestroyTensorDescriptor(inputDataTensorDescriptor));
		checkCUDNN(cudnnDestroyTensorDescriptor(outputDataTensorDescriptor));
		checkCUDNN(cudnnDestroyTensorDescriptor(biasTensorDescriptor));
		checkCUDNN(cudnnDestroyTensorDescriptor(poolingDataTensorDescriptor));
		checkCUDNN(cudnnDestroyFilterDescriptor(kernelDescriptor));
		checkCUDNN(cudnnDestroyConvolutionDescriptor(convolutionDescriptor));
		checkCUDNN(cudnnDestroyPoolingDescriptor(poolingDescriptor));

		return h_activation_output_data;
	}

};

int main() {

	//first group
	int batchSize = 1;
	int imageHeight = 540;
	int imageWidth = 540;
	int kernelHeight = 3;
	int kernelWidth = 3;
	int poolingWindowHeight = 3;
	int poolingWindowWidth = 3;
	int inputFeaturemaps = 1;
	int outputFeaturemaps = 1;

	//读取图片到RGB三个通道
	char imagePath[256];
	getcwd(imagePath, 256);
	strcat(imagePath, "/trainingset/");
	strcat(imagePath, "train1.png");
	std::vector<float> redChannel;
	std::vector<float> greenChannel;
	std::vector<float> blueChannel;
	float * h_red_channel_input_data;
	ImageProcessor processor;
	processor.readRGBImage(imagePath, &redChannel, &greenChannel, &blueChannel);
	redChannel = processor.imageChannelNormalization(&redChannel);
	greenChannel = processor.imageChannelNormalization(&greenChannel);
	blueChannel = processor.imageChannelNormalization(&blueChannel);
	h_red_channel_input_data = Utility::VectorToArray(&redChannel);

	//GPU设定
	int GPUs;
	checkCudaErrors(cudaGetDeviceCount(&GPUs));
	if (GPUs > 0) {
		checkCudaErrors(cudaSetDevice(0));
	} else {
		return 0;
	}

	//cudnn初始化
	cudnnHandle_t cudnnHandle = NULL;
	cudnnCreate(&cudnnHandle);

	SceneLabeling sceneLabeling;

	float * first_group_output_data =
			sceneLabeling.convolution_maxpooling_sigmoid(cudnnHandle,
					h_red_channel_input_data, batchSize, imageHeight,
					imageWidth, kernelHeight, kernelWidth, poolingWindowHeight,
					poolingWindowWidth, inputFeaturemaps, outputFeaturemaps);

}
