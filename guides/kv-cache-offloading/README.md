# Well-lit Path: KV Cache Offloading

## Overview

Efficient caching of attention Key & Value (KV) tensors is crucial for boosting Large Language Model (LLM) inference performance such as Time to First Token (TTFT) and overall throughput, as well as reducing the cost. Caching in the accelerator High-Bandwidth Memory (HBM) is a free lunch that state of the art inference engines already take. Yet more tokens and memory in GenAI applications demands more KV caching, driving the need for offloading KV cache from HBM to more storage options. This well-lit path contains multiple sub-guides per the KV storage type, with high level guidance on when to use them.

### CPU RAM

Enabling KV cache offloading to CPU is recommended for the following reasons:

* Little operational overhead.
* There are usually more CPU RAM storage available than accelerator HBM on the host offering much larger cache capacity.
* CPU - accelerator transfer is faster than recomputation for most cases.
* (WIP) KV storage tier aware inference scheduling makes smart decisions based on cache tier (accelerator HBM vs. CPU RAM).

In low cache size scenario where HBM is primarily used, async CPU offloading should incur little overhead. In high cache size scenario loading cache from CPU RAM offers significantly higher cache hit and thus better performance than HBM only.

### Shared Storage

Offloading KV cache to a shared(remote) storage offers the following benefits:

* Massive storage capacity independent of the inference engine deployment capacity.
* Seamlessly share KV cache across inference engine replicas and restarts.

However, it adds both operational and performance overhead, depending on the characteristics (such as latency and throughput) of the storage system. Thus the decision of offloading to a shared storage system needs careful consideration.

Consider a shared storage option when at least one of the following applies:

* Large cache capacity requirement beyond HBM + CPU RAM.
* Long input size (>10k) and high cache hits.
* Frequent cache migration needs (e.g., model or engine rollouts).
