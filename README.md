# ingress Helm Chart

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Helm Version](https://img.shields.io/badge/Helm-3.x-blue)
![Kubernetes Version](https://img.shields.io/badge/Kubernetes-1.19%2B-green)

A reusable Helm chart for managing one or more Kubernetes Ingress resources with advanced rule grouping, ALB condition generation, ExternalDNS integration, and optional Prometheus Blackbox monitoring.

Version: **0.5.2**

---

## Requirements

- **Helm 3.x**
- **Kubernetes 1.19+**
- (Optional) **AWS Load Balancer Controller** — for ALB support and condition annotations  
- (Optional) **ExternalDNS** — for automatic Route53 record management  
- (Optional) **Prometheus Operator** — for creating `ServiceMonitor` objects  

---

## Overview

This chart is designed to simplify and optimize complex ingress configurations in AWS EKS or any Kubernetes-based platform.  
It is particularly effective for environments that host **many microservices behind a single Application Load Balancer (ALB)** — a common scenario in cost-optimized development or staging environments.

By **consolidating multiple ingress definitions into one ALB**, this chart:
- Reduces the total number of AWS ALBs required (lowering cost by up to 60–70% in non-production setups)
- Automatically groups backend services and hosts into minimal ALB rule sets
- Ensures predictable DNS and TLS handling without manual annotation maintenance

This approach aligns with the same **cost-optimization principles** from the RDS/EKS scheduling study — grouping, automation, and declarative resource definition to reduce operational overhead and infrastructure cost.

---

## How It Works

Each item defined under `ingresses:` in `values.yaml` represents one Kubernetes `Ingress` resource.

### Rule Grouping Logic

When `generateALBGroupedRules: true` is set, the chart dynamically groups paths and hosts based on shared backend targets.  
Rules are grouped by:

- **Service Name**
- **Service Port or Port Number**

Each group can include:
- Up to **4 paths per ALB condition/action block** (practical chunk size under AWS ALB’s rule limits)  
- Multiple hosts sharing the same service, automatically grouped by host header

This drastically reduces the total number of ALB rules required for environments with many microservices or routes.  
For example, instead of 40 separate ALB rules (one per path), the grouping mechanism can collapse them into **10 grouped rules**, improving provisioning speed and minimizing configuration size.

The chart generates the required ALB annotations automatically:
```
alb.ingress.kubernetes.io/actions.<group>
alb.ingress.kubernetes.io/conditions.<group>
```

The backend target mapping uses “use-annotation” forwarding, meaning the Ingress backend refers to annotations instead of static service names. This allows complex forwarding rules without YAML duplication.

### ExternalDNS Integration

When `generateExternalDnsHostList: true` is enabled, all hosts defined in the Ingress are automatically collected and combined into:
```
external-dns.alpha.kubernetes.io/hostname: app.example.com,api.example.com
```
This ensures ExternalDNS keeps Route53 records synchronized even if some hosts will appear only in annotation for ALB rules.

### Prometheus Blackbox Monitoring

If `metrics.serviceMonitorBlackBox.enabled` is set to `true`, the chart creates one `ServiceMonitor` per target URL to probe your endpoints using the Prometheus Blackbox Exporter.  
This enables continuous uptime and latency monitoring for ingress routes directly from Prometheus.

---

## Installation

```
helm upgrade --install ingress ./ingress \
  --namespace your-namespace \
  -f values.yaml
```

Render manifests only:

```
helm template ingress ./ingress -f values.yaml
```

---

## Values Overview

| Key | Type | Default | Description |
|-----|------|----------|-------------|
| `ingresses` | map | `{}` | Map of ingress definitions |
| `ingresses.<name>.annotations` | map | `{}` | Custom ingress annotations |
| `ingresses.<name>.ingressClassName` | string | `""` | Ingress class (e.g., `alb`, `nginx`) |
| `ingresses.<name>.tls` | list | `[]` | Standard TLS block (`hosts`, `secretName`) |
| `ingresses.<name>.hosts` | list | `[]` | List of hosts and path definitions |
| `ingresses.<name>.generateExternalDnsHostList` | bool | `false` | Enable automatic ExternalDNS hostname annotation |
| `ingresses.<name>.generateALBGroupedRules` | bool | `false` | Enable ALB rule grouping and condition generation |
| `metrics.serviceMonitorBlackBox.enabled` | bool | `false` | Enable Prometheus Blackbox `ServiceMonitor` creation |
| `metrics.serviceMonitorBlackBox.targets` | list | `[]` | List of endpoints to probe |
| `metrics.serviceMonitorBlackBox.defaults` | map | *(see values.yaml)* | Default scrape configuration |

---

## Quick Reference Schema

For convenience, the following shows the typical structure of a `values.yaml` file:

```
ingresses:
  myapp:
    ingressClassName: alb
    generateExternalDnsHostList: true
    generateALBGroupedRules: true
    annotations: {}
    tls:
      - secretName: wildcard-example-com
        hosts:
          - app.example.com
    hosts:
      - host: app.example.com
        paths:
          - path: /
            serviceName: myapp
            servicePort: http
metrics:
  serviceMonitorBlackBox:
    enabled: false
    targets: []
```

---

## Example: Combined Setup

This example shows a typical scenario where two hosts share one ALB, using TLS, ExternalDNS, ALB grouping, and a Prometheus ServiceMonitor.

```
ingresses:
  webapp:
    ingressClassName: alb
    generateExternalDnsHostList: true
    generateALBGroupedRules: true
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/listen-ports: `[{"HTTP":80},{"HTTPS":443}]`
    tls:
      - secretName: wildcard-example-com
        hosts:
          - app.example.com
          - api.example.com
    hosts:
      - host: app.example.com
        paths:
          - path: /
            serviceName: app-service
            servicePort: http
          - path: /health
            serviceName: app-service
            servicePort: http
      - host: api.example.com
        paths:
          - path: /v1/*
            serviceName: api-service
            servicePortNumber: 8080

metrics:
  serviceMonitorBlackBox:
    enabled: true
    defaults:
      selector:
        matchLabels:
          app.kubernetes.io/name: prometheus-blackbox-exporter
      namespaceSelector: monitoring
      module: http_2xx
    targets:
      - name: webapp
        url: https://app.example.com/healthz
        hostname: app.example.com
        interval: 60s
        scrapeTimeout: 30s
```

---

## Benefits

- **Fewer ALBs:** Multiple services share one ALB while maintaining individual routing  
- **Simpler maintenance:** No manual ALB rule annotations  
- **Reduced AWS costs:** Consolidation reduces monthly load balancer cost by **60–70%** for dev/test clusters  
- **Declarative & version-controlled:** All routing logic in one `values.yaml`  
- **Monitoring built-in:** Optional endpoint checks via Prometheus Blackbox  

---

## Chart Structure

```
templates/
 ├─ _helpers.tpl            # Naming and labeling helpers
 ├─ _ingress.tpl            # Core ingress rendering logic with grouping
 ├─ ingress.yaml            # Renders all ingress resources defined under `ingresses`
 └─ servicemonitor.yaml     # Blackbox ServiceMonitor generation (optional)
```

---

## License

This chart is licensed under the **MIT License**.  
You can view the full license text here:  
[https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)

