# Caching Container Images for AWS Bottlerocket Instances
This solution was designed to reduce the boot time of cotainers on AWS Bottlerocket instances which need to pull large container image by caching the images in the data volume.

Data analytics and machine learning workload running in container are typical use cases which need large size container images, these images are usually more than 1 GiB size, while pulling and exacting an image from ECR with 1 GiB size(compressed) may take 1 minute to complete. Reducing time to pull image is the key to improve effeciency of booting these contaienrs.

[Bottlerocket](https://github.com/bottlerocket-os/bottlerocket) is a Linux-based open-source operating system that is purpose-built by AWS for running containers. There are 2 volumes(OS volume and data volume) in Bottlerocket, data volume is used to store artifacts and container images, this solution will use this volume to pull images and get the snapshot for later usage.

This solution will use Bottlerocket for EKS AMI to demostrate the process to cache images in EBS snapshot and then launch it in EKS cluster.

# How it works

![bottlerocket-image-cache drawio](https://user-images.githubusercontent.com/6355087/171136787-ec6b2269-8ebe-404e-acac-b1e4f7f96cd1.png)

1. Launch an EC2 instance with Bottlerocket for EKS AMI, then pull images which need to cache in this EC2.
2. Build the EBS snapshot for the data volume.
3. Launch instance with the EBS snapshot.

# Setps
1. Set up [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html), [eksctl](https://github.com/weaveworks/eksctl) and kubectl in your development environment(Linux or MacOS).
2. Clone this projects in your local environment.
3. Modify ```snapshot.sh``` to set AWS_DEFAULT_REGION and IMAGES you want to cache.
4. Run ```snapshot.sh``` to build the EBS snapshot.
5. Modify ```cluster.sh``` to set CLUSTER_NAME, EBS_SNAPSHOT_ID and AWS_DEFAULT_REGION
6. Run ```cluster.sh``` to build the testing cluster.
7. Run ```kubectl get node``` to list the worker nodes with cached images.
