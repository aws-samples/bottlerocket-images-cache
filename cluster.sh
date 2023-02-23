#!/bin/bash
set -e

CLUSTER_NAME="fastboot"
EBS_SNAPSHOT_ID="snap-0123456789abc"
AWS_DEFAULT_REGION="us-west-2"

# 1. deploy EKS cluster
eksctl create cluster -f - << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: '1.24'
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

iam:
  withOIDC: true

fargateProfiles:
  - name: system
    selectors:
      - namespace: kube-system
      - namespace: karpenter

karpenter:
  version: 'v0.25.0'
  createServiceAccount: true
EOF

# 3. deploy karpenter provisioner with data volume EBS snapshot
kubectl apply -f - << EOF
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
    - key: "node.kubernetes.io/instance-type"
      operator: In
      values: ["m5.large", "m5.2xlarge"]
  limits:
    resources:
      cpu: 1000
  providerRef:
    name: default
  ttlSecondsAfterEmpty: 30
---
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  subnetSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  amiFamily: Bottlerocket
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 2Gi
        volumeType: gp3
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 80Gi
        volumeType: gp3
        snapshotID: ${EBS_SNAPSHOT_ID}
EOF

# kubectl set env daemonset aws-node -n kube-system WARM_IP_TARGET=1
# sleep 5

# 4. deploy test pod
kubectl apply -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
spec:
  replicas: 1
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.2
          resources:
            requests:
              cpu: 1
EOF
