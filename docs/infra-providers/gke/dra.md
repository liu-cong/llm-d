Follow https://cloud.google.com/kubernetes-engine/docs/how-to/set-up-dra.
NOTE: I only did this:
```
gcloud container clusters update conliu-test \
    --location=europe-west1 \
    --enable-kubernetes-unstable-apis="resource.k8s.io/v1beta1/deviceclasses,resource.k8s.io/v1beta1/resourceclaims,resource.k8s.io/v1beta1/resourceclaimtemplates,resource.k8s.io/v1beta1/resourceslices"
```
## Cluster Version
1.34.1-gke.2037000 (for GKE managed DRANET)
## Create nodepool;

```
export REGION="europe-west1"
export ZONE="europe-west1-b"
export PROJECT="conliu-gke-dev"
export GVNIC_NETWORK_PREFIX="gkekmp-gvnic-${REGION}"
export RDMA_NETWORK_PREFIX="gkekmp-rdma-${REGION}"
export CLUSTER_NAME="conliu-test"
export NODE_COUNT=2
# Use the following for h200
export NODE_POOL_NAME="h200-2"
export MACHINE_TYPE="a3-ultragpu-8g"
export ACCELERATOR_CONFIG="type=nvidia-h200-141gb,count=8,gpu-driver-version=latest"
```

gcloud container node-pools create ${NODE_POOL_NAME}-cos --project ${PROJECT} --placement-type COMPACT \
 --region ${REGION} --cluster ${CLUSTER_NAME} --num-nodes=${NODE_COUNT} \
 --machine-type ${MACHINE_TYPE} --accelerator ${ACCELERATOR_CONFIG}  --node-locations "${ZONE}" \
 --additional-node-network network=${GVNIC_NETWORK_PREFIX}-net,subnetwork=${GVNIC_NETWORK_PREFIX}-sub \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-0 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-1 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-2 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-3 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-4 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-5 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-6 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-7 \
 --spot

gcloud container node-pools create ${NODE_POOL_NAME}-cos --project ${PROJECT} --placement-type COMPACT \
 --region ${REGION} --cluster ${CLUSTER_NAME} --num-nodes=${NODE_COUNT} \
 --machine-type ${MACHINE_TYPE} --accelerator ${ACCELERATOR_CONFIG}  --node-locations "${ZONE}" \
 --additional-node-network network=${GVNIC_NETWORK_PREFIX}-net,subnetwork=${GVNIC_NETWORK_PREFIX}-sub \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-0 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-1 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-2 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-3 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-4 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-5 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-6 \
 --additional-node-network network=${RDMA_NETWORK_PREFIX}-net,subnetwork=${RDMA_NETWORK_PREFIX}-sub-7 \
--node-labels="cloud.google.com/gke-networking-dra-driver=true,nvidia.com/gpu.present=true" \
 --spot

gcloud beta container node-pools create h200-3 \
  --placement-type COMPACT \
  --region=europe-west1 \
  --cluster=conliu-test \
  --node-locations=europe-west1-b \
  --accelerator type=nvidia-h200-141gb,count=8,gpu-driver-version=latest \
  --machine-type=a3-ultragpu-8g \
  --num-nodes=2 \
  --accelerator-network-profile=auto \
  --node-labels="cloud.google.com/gke-networking-dra-driver=true,nvidia.com/gpu.present=true" \
  --spot

NOTE: DO NOT use the `--accelerator-network-profile=auto ` method to create NP, it doesn't set kube_env `SET_MEMLOCK_LIMIT_UNLIMITED`, and the container will fail with error: 
```
# UCX  ERROR mlx5_5: ibv_create_srq() failed: Cannot allocate memory : Please set max locked memory (ulimit -l) to 'unlimited' (current: 8192 kbytes)

```

## Install DRANET
Use GKE manged: https://cloud.google.com/kubernetes-engine/docs/how-to/allocate-network-resources-dra#use-rdma-interfaces-gpu

## Install NVIDIA DRA Driver

helm upgrade -i --create-namespace --namespace nvidia-dra-driver-gpu nvidia-dra-driver-gpu ./k8s-dra-driver-gpu/deployments/helm/nvidia-dra-driver-gpu --values https://raw.githubusercontent.com/google/dranet/refs/heads/main/examples/demo_nvidia_dranet/values.yaml --set image.tag=v25.8.0 --wait

* Update nodes with label nvidia.com/gpu.present=true (because the nvidia dra driver installs a daemon on nodes matching that)
