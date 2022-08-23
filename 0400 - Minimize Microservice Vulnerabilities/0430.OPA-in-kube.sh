#!/bin/bash

#### Развертывание OPA kube-mgmt в однонодном кластере

kubectl taint node controlplane node-role.kubernetes.io/master-
kubectl taint node controlplane node-role.kubernetes.io/controlplane-

touch .rnd
kubectl create namespace opa
kubectl config set-context opa-tutorial --user kubernetes-admin --cluster kubernetes --namespace opa
kubectl config use-context opa-tutorial
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -sha256 -key ca.key -days 100000 -out ca.crt -subj "/CN=admission_ca"


cat >server.conf <<EOF
[ req ]
prompt = no
req_extensions = v3_ext
distinguished_name = dn

[ dn ]
CN = opa.opa.svc

[ v3_ext ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, serverAuth
subjectAltName = DNS:opa.opa.svc,DNS:opa.opa.svc.cluster,DNS:opa.opa.svc.cluster.local
EOF


openssl genrsa -out server.key 2048
openssl req -new -key server.key -sha256 -out server.csr -extensions v3_ext -config server.conf
openssl x509 -req -in server.csr -sha256 -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 100000 -extensions v3_ext -extfile server.conf


kubectl create secret tls opa-server --cert=server.crt --key=server.key --namespace opa


cat >admission-controller.yaml <<EOF
# Grant OPA/kube-mgmt read-only access to resources. This lets kube-mgmt
# replicate resources into OPA so they can be used in policies.
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: opa-viewer
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: Group
  name: system:serviceaccounts:opa
  apiGroup: rbac.authorization.k8s.io
---
# Define role for OPA/kube-mgmt to update configmaps with policy status.
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: opa
  name: configmap-modifier
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["update", "patch"]
---
# Grant OPA/kube-mgmt role defined above.
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: opa
  name: opa-configmap-modifier
roleRef:
  kind: Role
  name: configmap-modifier
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: Group
  name: system:serviceaccounts:opa
  apiGroup: rbac.authorization.k8s.io
---
kind: Service
apiVersion: v1
metadata:
  name: opa
  namespace: opa
spec:
  selector:
    app: opa
  ports:
  - name: https
    protocol: TCP
    port: 443
    targetPort: 8443
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: opa
  namespace: opa
  name: opa
spec:
  replicas: 1
  selector:
    matchLabels:
      app: opa
  template:
    metadata:
      labels:
        app: opa
      name: opa
    spec:
      containers:
        # WARNING: OPA is NOT running with an authorization policy configured. This
        # means that clients can read and write policies in OPA. If you are
        # deploying OPA in an insecure environment, be sure to configure
        # authentication and authorization on the daemon. See the Security page for
        # details: https://www.openpolicyagent.org/docs/security.html.
        - name: opa
          image: openpolicyagent/opa:0.43.0-rootless
          args:
            - "run"
            - "--server"
            - "--tls-cert-file=/certs/tls.crt"
            - "--tls-private-key-file=/certs/tls.key"
            - "--addr=0.0.0.0:8443"
            - "--addr=http://127.0.0.1:8181"
            - "--log-format=json-pretty"
            - "--set=status.console=true"
            - "--set=decision_logs.console=true"
          volumeMounts:
            - readOnly: true
              mountPath: /certs
              name: opa-server
          readinessProbe:
            httpGet:
              path: /health?plugins&bundle
              scheme: HTTPS
              port: 8443
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              scheme: HTTPS
              port: 8443
            initialDelaySeconds: 3
            periodSeconds: 5
        - name: kube-mgmt
          image: openpolicyagent/kube-mgmt:2.0.1
          args:
            - "--replicate-cluster=v1/namespaces"
            - "--replicate=networking.k8s.io/v1/ingresses"
      volumes:
        - name: opa-server
          secret:
            secretName: opa-server
EOF

cat > main.rego.cm.yaml <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: opa-default-system-main
  namespace: opa
data:
  main: |
    package system

    import data.kubernetes.admission

    main := {
      "apiVersion": "admission.k8s.io/v1",
      "kind": "AdmissionReview",
      "response": response,
    }

    default uid := ""

    uid := input.request.uid

    response := {
        "allowed": false,
        "uid": uid,
        "status": {
            "message": reason,
    },
    } {
        reason = concat(", ", admission.deny)
        reason != ""
    }

    else := {"allowed": true, "uid": uid}
EOF


### В моем новом кластере могут не успеть подняться сетевые аддоны, в уже работающем эти циклы не нужны
until kubectl get po -n kube-system | grep flannel | grep -w Running; do
    sleep 1
done

until kubectl get po -n kube-system | grep coredns | grep -w Running | wc -l | grep 2; do
    sleep 1
done

kubectl apply -f admission-controller.yaml
kubectl apply -f main.rego.cm.yaml

cat > webhook-configuration.yaml <<EOF
kind: ValidatingWebhookConfiguration
apiVersion: admissionregistration.k8s.io/v1
metadata:
  name: opa-validating-webhook
webhooks:
  - name: validating-webhook.openpolicyagent.org
    namespaceSelector:
      matchExpressions:
      - key: openpolicyagent.org/webhook
        operator: NotIn
        values:
        - ignore
    rules:
      - operations: ["CREATE", "UPDATE"]
        apiGroups: ["*"]
        apiVersions: ["*"]
        resources: ["*"]
    clientConfig:
      caBundle: $(cat ca.crt | base64 | tr -d '\n')
      service:
        namespace: opa
        name: opa
    admissionReviewVersions: ["v1"]
    sideEffects: None
EOF

kubectl label ns kube-system openpolicyagent.org/webhook=ignore
kubectl label ns opa openpolicyagent.org/webhook=ignore

kubectl apply -f webhook-configuration.yaml

# В kubeadm по умолчанию не включен контроллер вебхука
sed -i 's/--enable-admission-plugins=NodeRestriction/--enable-admission-plugins=NodeRestriction,ValidatingAdmissionWebhook/g' /etc/kubernetes/manifests/kube-apiserver.yaml



