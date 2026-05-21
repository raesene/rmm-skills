# Volume Mount Examples

Common volume mount configurations for kubeadm static pod manifests.

## Audit Logging

**Host setup:**
```bash
mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
```

**Volume + mount for policy file (read-only):**
```yaml
# spec.volumes
- name: audit-policy
  hostPath:
    path: /etc/kubernetes/audit
    type: DirectoryOrCreate

# spec.containers[0].volumeMounts
- name: audit-policy
  mountPath: /etc/kubernetes/audit
  readOnly: true
```

**Volume + mount for audit log output (read-write):**
```yaml
# spec.volumes
- name: audit-log
  hostPath:
    path: /var/log/kubernetes/audit
    type: DirectoryOrCreate

# spec.containers[0].volumeMounts
- name: audit-log
  mountPath: /var/log/kubernetes/audit
```

**Flags:**
```
- --audit-policy-file=/etc/kubernetes/audit/policy.yaml
- --audit-log-path=/var/log/kubernetes/audit/audit.log
- --audit-log-maxage=30
- --audit-log-maxbackup=10
- --audit-log-maxsize=100
```

## Encryption at Rest

**Host setup:**
```bash
mkdir -p /etc/kubernetes/encryption
# Create encryption config at /etc/kubernetes/encryption/config.yaml
```

**Volume + mount:**
```yaml
# spec.volumes
- name: encryption-config
  hostPath:
    path: /etc/kubernetes/encryption
    type: DirectoryOrCreate

# spec.containers[0].volumeMounts
- name: encryption-config
  mountPath: /etc/kubernetes/encryption
  readOnly: true
```

**Flag:**
```
- --encryption-provider-config=/etc/kubernetes/encryption/config.yaml
```

## Webhook Admission (e.g., OPA/Gatekeeper, custom admission)

**Host setup:**
```bash
mkdir -p /etc/kubernetes/webhook
# Create webhook kubeconfig at /etc/kubernetes/webhook/admission-config.yaml
```

**Volume + mount:**
```yaml
# spec.volumes
- name: webhook-config
  hostPath:
    path: /etc/kubernetes/webhook
    type: DirectoryOrCreate

# spec.containers[0].volumeMounts
- name: webhook-config
  mountPath: /etc/kubernetes/webhook
  readOnly: true
```

**Flags:**
```
- --admission-control-config-file=/etc/kubernetes/webhook/admission-config.yaml
```

## OIDC Authentication

When using OIDC with a custom CA, mount the CA certificate:

```yaml
# spec.volumes
- name: oidc-ca
  hostPath:
    path: /etc/kubernetes/oidc
    type: DirectoryOrCreate

# spec.containers[0].volumeMounts
- name: oidc-ca
  mountPath: /etc/kubernetes/oidc
  readOnly: true
```

**Flags:**
```
- --oidc-issuer-url=https://accounts.example.com
- --oidc-client-id=kubernetes
- --oidc-ca-file=/etc/kubernetes/oidc/ca.pem
- --oidc-username-claim=email
- --oidc-groups-claim=groups
```
