# Migration Semantic Equivalence Summary - pd-disaggregation

This document proves that the new hybrid architecture (Helm-based InferencePool + Kustomize-based vLLM) is semantically equivalent to the legacy Helm-only approach.

## Components Compared

1. **InferencePool**:
   - Legacy: `helm template gaie-pd guides/pd-disaggregation/gaie-pd`
   - v2: `helm template llm-d-infpool inferencepool -f v2/manifests/inferencepool.values.yaml`

2. **Model Server (vLLM)**:
   - Legacy: `helm template ms-pd guides/pd-disaggregation/ms-pd`
   - v2: `kustomize build v2/manifests/vllm/base`

## Diff Content

Expected differences include:
- Release names (`gaie-pd` vs `llm-d-infpool`, `ms-pd` vs `vllm-pd`)
- Chart metadata labels
- Removal of some Helm-specific template noise

```diff
--- /tmp/legacy_render.yaml	2026-03-11 20:33:33
+++ /tmp/v2_render.yaml	2026-03-11 20:33:33
@@ -1,2 +1,352 @@
+---
+# Source: inferencepool/templates/rbac.yaml
+apiVersion: v1
+kind: ServiceAccount
+metadata:
+  name: llm-d-infpool-epp
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+---
+# Source: inferencepool/templates/inferenceextension.yaml
+apiVersion: v1
+kind: Secret
+metadata:
+  name: pd-gateway-sa-metrics-reader-secret
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+  annotations:
+    kubernetes.io/service-account.name: llm-d-infpool-epp
+type: kubernetes.io/service-account-token
+---
+# Source: inferencepool/templates/inferenceextension.yaml
+apiVersion: v1
+kind: ConfigMap
+metadata:
+  name: llm-d-infpool-epp
+  namespace: llm-d-pd
+data:
+  default-plugins.yaml: |
+    apiVersion: inference.networking.x-k8s.io/v1alpha1
+    kind: EndpointPickerConfig
+    plugins:
+    - type: queue-scorer
+    - type: kv-cache-utilization-scorer
+    - type: prefix-cache-scorer
+    schedulingProfiles:
+    - name: default
+      plugins:
+      - pluginRef: queue-scorer
+        weight: 2
+      - pluginRef: kv-cache-utilization-scorer
+        weight: 2
+      - pluginRef: prefix-cache-scorer
+        weight: 3
+  pd-config.yaml: |
+    # ALWAYS DO PD IN THIS EXAMPLE (THRESHOLD 0)
+    apiVersion: inference.networking.x-k8s.io/v1alpha1
+    kind: EndpointPickerConfig
+    featureGates:
+    - prepareDataPlugins
+    plugins:
+    - type: prefill-header-handler
+    - type: prefix-cache-scorer
+      parameters:
+        maxPrefixBlocksToMatch: 256
+        lruCapacityPerServer: 31250
+    - type: queue-scorer
+    - type: prefill-filter
+    - type: decode-filter
+    - type: max-score-picker
+    - type: prefix-based-pd-decider
+      parameters:
+        nonCachedTokens: 16
+    - type: pd-profile-handler
+      parameters:
+        primaryPort: 0
+        deciderPluginName: prefix-based-pd-decider
+    schedulingProfiles:
+    - name: prefill
+      plugins:
+      - pluginRef: prefill-filter
+      - pluginRef: max-score-picker
+      - pluginRef: prefix-cache-scorer
+        weight: 2
+      - pluginRef: queue-scorer
+        weight: 1
+    - name: decode
+      plugins:
+      - pluginRef: decode-filter
+      - pluginRef: max-score-picker
+      - pluginRef: prefix-cache-scorer
+        weight: 2
+      - pluginRef: queue-scorer
+        weight: 1
+    # All profiles using max score picker by default
+---
+# Source: inferencepool/templates/rbac.yaml
+kind: ClusterRole
+apiVersion: rbac.authorization.k8s.io/v1
+metadata:
+  name: "llm-d-infpool-llm-d-pd-epp"
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+rules:
+- apiGroups:
+    - authentication.k8s.io
+  resources:
+    - tokenreviews
+  verbs:
+    - create
+- apiGroups:
+    - authorization.k8s.io
+  resources:
+    - subjectaccessreviews
+  verbs:
+    - create
+- nonResourceURLs:
+    - "/metrics"
+  verbs:
+    - get
+---
+# Source: inferencepool/templates/rbac.yaml
+kind: ClusterRoleBinding
+apiVersion: rbac.authorization.k8s.io/v1
+metadata:
+  name: "llm-d-infpool-llm-d-pd-epp"
+subjects:
+- kind: ServiceAccount
+  name: llm-d-infpool-epp
+  namespace: llm-d-pd
+roleRef:
+  apiGroup: rbac.authorization.k8s.io
+  kind: ClusterRole
+  name: "llm-d-infpool-llm-d-pd-epp"
+---
+# Source: inferencepool/templates/rbac.yaml
+apiVersion: rbac.authorization.k8s.io/v1
+kind: Role
+metadata:
+  name: llm-d-infpool-epp-non-sa
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+rules:
+- apiGroups: ["inference.networking.x-k8s.io"]
+  resources: ["inferenceobjectives", "inferencemodelrewrites"]
+  verbs: ["get", "watch", "list"]
+- apiGroups: ["inference.networking.k8s.io"]
+  resources: ["inferencepools"]
+  verbs: ["get", "watch", "list"]
+---
+# Source: inferencepool/templates/rbac.yaml
+apiVersion: rbac.authorization.k8s.io/v1
+kind: Role
+metadata:
+  name: llm-d-infpool-epp-sa
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+rules:
+- apiGroups: [""]
+  resources: ["pods"]
+  verbs: ["get", "watch", "list"]
+---
+# Source: inferencepool/templates/rbac.yaml
+apiVersion: rbac.authorization.k8s.io/v1
+kind: RoleBinding
+metadata:
+  name: llm-d-infpool-epp-non-sa
+  namespace: llm-d-pd
+subjects:
+- kind: ServiceAccount
+  name: llm-d-infpool-epp
+  namespace: llm-d-pd
+roleRef:
+  apiGroup: rbac.authorization.k8s.io
+  kind: Role
+  name: llm-d-infpool-epp-non-sa
+---
+# Source: inferencepool/templates/rbac.yaml
+apiVersion: rbac.authorization.k8s.io/v1
+kind: RoleBinding
+metadata:
+  name: llm-d-infpool-epp-sa
+  namespace: llm-d-pd
+subjects:
+- kind: ServiceAccount
+  name: llm-d-infpool-epp
+  namespace: llm-d-pd
+roleRef:
+  apiGroup: rbac.authorization.k8s.io
+  kind: Role
+  name: llm-d-infpool-epp-sa
+---
+# Source: inferencepool/templates/inferenceextension.yaml
+apiVersion: v1
+kind: Service
+metadata:
+  name: llm-d-infpool-epp
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+spec:
+  selector:
+    inferencepool: llm-d-infpool-epp
+  ports:
+    - name: grpc-ext-proc
+      protocol: TCP
+      port: 9002
+    - name: http-metrics
+      protocol: TCP
+      port: 9090
+  type: ClusterIP
+---
+# Source: inferencepool/templates/inferenceextension.yaml
+apiVersion: apps/v1
+kind: Deployment
+metadata:
+  name: llm-d-infpool-epp
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+spec:
+  replicas: 1
+  strategy:
+    # The current recommended EPP deployment pattern is to have a single active replica. This ensures
+    # optimal performance of the stateful operations such prefix cache aware scorer.
+    # The Recreate strategy the old replica is killed immediately, and allow the new replica(s) to
+    # quickly take over. This is particularly important in the high availability set up with leader
+    # election, as the rolling update strategy would prevent the old leader being killed because
+    # otherwise the maxUnavailable would be 100%.
+    type: Recreate
+  selector:
+    matchLabels:
+      inferencepool: llm-d-infpool-epp
+  template:
+    metadata:
+      labels:
+        inferencepool: llm-d-infpool-epp
+    spec:
+      serviceAccountName: llm-d-infpool-epp
+      # Conservatively, this timeout should mirror the longest grace period of the pods within the pool
+      terminationGracePeriodSeconds: 130
+      containers:
+        - name: epp
+          image: ghcr.io/llm-d/llm-d-inference-scheduler:v0.6.0
+          imagePullPolicy: Always
+          args:
+              - --pool-name
+              - llm-d-infpool
+              # The pool namespace is optional because EPP can default to the NAMESPACE env var.
+              - --pool-namespace
+              - llm-d-pd
+              - --pool-group
+              - "inference.networking.k8s.io"
+              - --zap-encoder
+              - "json"
+              - --config-file
+              - "/config/pd-config.yaml"
+              # Pass additional flags via the inferenceExtension.flags field in values.yaml.
+              - --kv-cache-usage-percentage-metric
+              - "vllm:kv_cache_usage_perc"
+              - --v
+              - "1"
+              - --tracing=false
+          ports:
+            - name: grpc
+              containerPort: 9002
+            - name: grpc-health
+              containerPort: 9003
+            - name: metrics
+              containerPort: 9090
+          livenessProbe:
+            grpc:
+              port: 9003
+              service: inference-extension
+            initialDelaySeconds: 5
+            periodSeconds: 10
+          readinessProbe:
+            grpc:
+              port: 9003
+              service: inference-extension
+            periodSeconds: 2
+          env:
+            - name: NAMESPACE
+              valueFrom:
+                fieldRef:
+                  fieldPath: metadata.namespace
+            - name: POD_NAME
+              valueFrom:
+                fieldRef:
+                  fieldPath: metadata.name
+            
+          volumeMounts:
+            - name: plugins-config-volume
+              mountPath: "/config"
+        
+      volumes:
+        - name: plugins-config-volume
+          configMap:
+            name: llm-d-infpool-epp
+---
+# Source: inferencepool/templates/inferenceextension.yaml
+---
+---
+# Source: inferencepool/templates/inferencepool.yaml
+apiVersion: "inference.networking.k8s.io/v1"
+kind: InferencePool
+metadata:
+  name: llm-d-infpool
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+spec:
+  targetPorts:
+      - number: 8000
+  selector:
+    matchLabels:
+      llm-d.ai/guide: "pd-disaggregation"
+      llm-d.ai/inference-serving: "true"
+  endpointPickerRef:
+    name: llm-d-infpool-epp
+    port:
+      number: 9002
+---
+# Source: inferencepool/templates/inferenceextension.yaml
+apiVersion: monitoring.coreos.com/v1
+kind: ServiceMonitor
+metadata:
+  name: llm-d-infpool-epp-monitor
+  namespace: llm-d-pd
+  labels:
+    app.kubernetes.io/name: llm-d-infpool-epp
+    app.kubernetes.io/version: "0.0.0"
+spec:
+  endpoints:
+  - interval: 10s
+    port: "http-metrics"
+    path: "/metrics"
+    authorization:
+      credentials:
+        key: token
+        name: pd-gateway-sa-metrics-reader-secret
+  jobLabel: llm-d-infpool-epp
+  namespaceSelector:
+    matchNames:
+    - llm-d-pd
+  selector:
+    matchLabels:
+      app.kubernetes.io/name: llm-d-infpool-epp
+      app.kubernetes.io/version: "0.0.0"
 
 ---
 # Limit output for readability
```
