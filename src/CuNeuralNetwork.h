/*
 * CuNeuralNetwork.h
 *
 *  Created on: Aug 17, 2015
 *      Author: ryukinkou
 */

#ifndef CUNEURALNETWORK_H_
#define CUNEURALNETWORK_H_

#include <cuda_runtime.h>
#include <cudnn.h>

struct OutputDim {

public:

	int outputImages;
	int outputFeaturemapsForEachImage;
	int outputFeaturemapHeight;
	int outputFeaturemapWidth;

};

class CuNeuralNetwork {

public:

	float * createInputDataLayer(float * h_input_data,
			cudnnTensorDescriptor_t * inputDataTensorDescriptor, int batchSize,
			int inputFeaturemaps, int imageHeight, int imageWidth);

	float * createKernel(float * h_kernel,
			cudnnFilterDescriptor_t * kernelDescriptor, int inputFeaturemaps,
			int outputFeaturemaps, int kernelHeight, int kernelWidth);

	float * createOutputDataLayer(
			cudnnTensorDescriptor_t * inputDataTensorDescriptor,
			cudnnFilterDescriptor_t * kernelDescriptor,
			cudnnConvolutionDescriptor_t * convolutionDescriptor,
			cudnnTensorDescriptor_t * outputDataTensorDescriptor,
			OutputDim * outputDim);

	float * addBiasUnits(float * h_bias,
			cudnnTensorDescriptor_t * biasTensorDescriptor,
			int outputFeaturemaps, int kernelHeight, int kernelWidth);

	float * createPoolingLayer(float * d_output_data,
			cudnnTensorDescriptor_t * inputDataTensorDescriptor,
			cudnnPoolingDescriptor_t * poolingDescriptor,
			cudnnTensorDescriptor_t * poolingDataTensorDescriptor,
			OutputDim * outputDim, int poolingWindowHeight,
			int poolingWindowWidth, int poolingVerticalStride,
			int poolingHorizontalStride, OutputDim * poolingOutputDim);

};

#endif /* CUNEURALNETWORK_H_ */
