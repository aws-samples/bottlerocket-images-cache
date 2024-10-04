# Caching Container Images for AWS Bottlerocket Instances
The purpose of this sample is to reduce the boot time of containers with large images by caching the images in the data volume of Bottlerocket OS.

Data analytics and machine learning workloads often require large container images (usually measured by Gigabytes), which can take several minutes to pull and extract from Amazon ECR or other image registry. Reduce image pulling time is the key of improving efficiency of launching these containers.

[Bottlerocket OS](https://github.com/bottlerocket-os/bottlerocket) is a Linux-based open-source operating system built by AWS specifically for running containers. It has two volumes, an OS volume and a data volume, with the latter used for storing artifacts and container images. This sample will leverage the data volume to pull images and take snapshots for later usage.

To demonstrate the process of caching images in EBS snapshots and launching them in an EKS cluster, this sample will use Amazon EKS optimized Bottlerocket AMIs.

## How this script works

![bottlerocket-image-cache drawio](images/bottlerocket-image-cache.png)

1. Launch an EC2 instance with Bottlerocket for EKS AMI,
2. Access to instance via Amazon System Manager
3. Pull images to be cached in this EC2 using Amazon System Manager Run Command.
4. Shut down the instance, build the EBS snapshot for the data volume.
5. Terminate the instance.

## Build EBS snapshot with cached container image
1. Set up [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html)
2. Run the following command to clone this projects in your local environment.
    ```bash
    git clone https://github.com/aws-samples/bottlerocket-images-cache/
    cd bottlerocket-images-cache/
    ```

3. Run `snapshot.sh` to build the EBS snapshot. Replace `us-west-2` to your region, and replace `public.ecr.aws/eks-distro/kubernetes/pause:3.2` to a comma seperated list of container images.
    ```bash
    ./snapshot.sh -r us-west-2 public.ecr.aws/eks-distro/kubernetes/pause:3.2
    ```

## Command-line Parameters

```bash
$ ./snapshot.sh -h
usage: ./snapshot.sh [options] <comma seperated container images>
Build EBS snapshot for Bottlerocket data volume with cached container images
Options:
-h,--help Print this help.
-r,--region Set AWS region to build the EBS snapshot. (default: use environment variable of AWS_DEFAULT_REGION or IMDS)
-a,--ami Set SSM Parameter path for Bottlerocket ID. (default: /aws/service/bottlerocket/aws-k8s-1.27/x86_64/latest/image_id)
-i,--instance-type Set EC2 instance type to build this snapshot. (default: m5.large)
-e,--encrypt Encrypt the generated snapshot. (default: false)
-k,--kms-id Use a specific KMS Key Id to encrypt this snapshot, should use together with -e
-s,--snapshot-size Use a specific volume size (in GiB) for this snapshot. (default: 50)
-R,--instance-role Name of existing IAM role for created EC2 instance. (default: Create on launching)
-q,--quiet Redirect output to stderr and output generated snapshot ID to stdout only. (default: false)
-sg,--security-group-id Set a specific Security Group ID for the instance. (default: use default VPC security group)
-sn,--subnet-id Set a specific Subnet ID for the instance. (default: use default VPC subnet)
-p,--public-ip Associate a public IP address with the instance. (default: true)
```

## Required IAM Policy

This script requires the following IAM policies:

```
"cloudformation:*",
"iam:GetInstanceProfile",
"iam:CreateInstanceProfile",
"iam:AddRoleToInstanceProfile",
"iam:DeleteInstanceProfile",
"iam:RemoveRoleFromInstanceProfile",
"iam:PassRole",
"ec2:Describe*",
"ec2:RunInstances",
"ec2:TerminateInstances",
"ec2:StopInstances",
"ec2:StartInstances",
"ec2:CreateVolume",
"ec2:AssociateIamInstanceProfile",
"ec2:ReplaceIamInstanceProfileAssociation",
"ec2:DisassociateIamInstanceProfile",
"ec2:CreateLaunchTemplate",
"ec2:CreateLaunchTemplateVersion",
"ec2:ModifyLaunchTemplate",
"ec2:DeleteLaunchTemplate",
"ec2:CreateSnapshot",
"ssm:CancelCommand",
"ssm:SendCommand",
"ssm:ListCommands",
"ssm:DescribeInstanceInformation",
"ssm:ListCommandInvocations",
"ssm:GetCommandInvocation",
"ssm:DescribeInstanceProperties",
"ssm:GetParameters"
```

If you choose to encrypt the snapshot with KMS using the `--encrypt` and/or `--kms-id` option, the following IAM policies is required:

```
"kms:RetireGrant",
"kms:CreateGrant",
"kms:ReEncrypt*",
"kms:GenerateDataKey*",
"kms:Encrypt",
"kms:DescribeKey",
"kms:Decrypt"
```

If you let the script create required IAM role for you, the following IAM policies is required:

```
"iam:AttachRolePolicy",
"iam:CreateRole"
"iam:DeleteRole"
"iam:DetachRolePolicy"
"iam:ListRoles"
"iam:ListRolePolicies"
"iam:ListPolicies"
```

## Using snapshot with Amazon EKS

There are 3 approaches to provision Amazon EC2 nodes for Amazon EKS cluster:
* EKS Managed Node Group
* Self managed nodes
* EC2 Fleet managed by [Karpenter](https://karpenter.sh/)

You can use EBS snapshot created by the script with nodes created by all the approaches.

### With Managed Node Group or Self managed nodes

You can use a launch template to create volume from snapshot. When creating launch template, specify snapshot ID on volume with **device name** `/dev/xvdb` only. For detail, please refer to [Customizing managed nodes with launch templates](https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html) on Amazon EKS documentation.

### With Karpenter

You can specify snapshot ID in a Karpenter node template. You should also specify AMI used when provisioning node is `BottleRocket`. Add the content on `EC2NodeClass` (or `AWSNodeTemplate` on older release of Karpenter):

`v1beta1` API:
```yaml
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: Bottlerocket # Ensure OS is BottleRocket
  blockDeviceMappings:
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        kmsKeyID: "arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab" # Specify KMS ID if you use custom KMS key
        snapshotID: snap-0123456789 # Specify your snapshot ID here
```

`v1alpha1` API:
```yaml
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
spec:
  amiFamily: Bottlerocket # Ensure OS is BottleRocket
  blockDeviceMappings:
    - deviceName: /dev/xvdb # Make sure device name is /dev/xvdb
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        snapshotID: snap-0123456789 # Specify your snapshot ID here
        kmsKeyID: "arn:aws:kms:us-west-2:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab" # Specify KMS ID if you use custom KMS key
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
