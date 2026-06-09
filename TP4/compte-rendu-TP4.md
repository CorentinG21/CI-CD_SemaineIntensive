# Compte Rendu — TP4 : Kubernetes opérationnel et durcissement
**Mastère Expert IT — CI/CD & DevSecOps**  
**Groupe :** gGODON-DAUVEL  
**Date :** 09 juin 2026  
**Lien GitHub :** [CI-CD_SemaineIntensive](https://github.com/CorentinG21/CI-CD_SemaineIntensive.git)

---

## Table des matières

1. [Architecture et structure du chart](#1-architecture-et-structure-du-chart)
2. [Phase 1 — Cluster Kapsule et accès](#2-phase-1--cluster-kapsule-et-accès)
3. [Phase 2 — Packaging Helm](#3-phase-2--packaging-helm)
4. [Phase 3 — Ingress et probes](#4-phase-3--ingress-et-probes)
5. [Phase 4 — RBAC](#5-phase-4--rbac)
6. [Phase 5 — NetworkPolicies](#6-phase-5--networkpolicies)
7. [Phase 6 — Durcissement des pods](#7-phase-6--durcissement-des-pods)
8. [Phase 7 — Admission Kyverno et vérification de signature](#8-phase-7--admission-kyverno-et-vérification-de-signature)
9. [Mini-questionnaire](#9-mini-questionnaire)

---

## 1. Architecture et structure du chart

L'application est déployée sur un cluster Kubernetes managé Scaleway Kapsule via un chart Helm. Le cluster utilise Cilium comme CNI, ce qui permet l'application native des NetworkPolicies.

### Structure du chart Helm

```
chart/
├── Chart.yaml
├── values.yaml
├── values-staging.yaml
├── values-prod.yaml
└── templates/
    ├── deployment-api.yaml
    ├── deployment-db.yaml
    ├── deployment-cache.yaml
    ├── service-api.yaml
    ├── service-db.yaml
    ├── service-cache.yaml
    ├── ingress.yaml
    ├── serviceaccount.yaml
    ├── role.yaml
    ├── rolebinding.yaml
    ├── networkpolicy-deny-all.yaml
    ├── networkpolicy-allow.yaml
    └── resourcequota.yaml
```

### Paramétrage par values

Le chart est entièrement paramétrable via les fichiers de valeurs. Aucune valeur n'est codée en dur dans les templates.

| Paramètre | Staging | Production |
|---|---|---|
| `api.replicas` | 1 | 2 |
| `api.image` | `51.15.211.47:5050/root/tp1-ggodon-dauvel/api:<SHA>` | idem |
| `api.resources.limits.cpu` | `500m` | `1000m` |
| `api.resources.limits.memory` | `256Mi` | `512Mi` |
| `db.storage` | `1Gi` | `5Gi` |

### Schéma des NetworkPolicies

```
                        ┌─────────────────────────────────────┐
                        │     Namespace : ggodon-dauvel       │
                        │                                     │
  ┌──────────┐          │  ┌─────────┐      ┌─────────────┐   │
  │  Ingress │─────────►│  │   api   │─────►│     db      │   │
  └──────────┘          │  └────┬────┘      └─────────────┘   │
                        │       │                             │
                        │       ▼                             │
                        │  ┌─────────┐                        │
                        │  │  cache  │                        │
                        │  └─────────┘                        │
                        │                                     │
                        │  Deny-all par défaut                │
                        └─────────────────────────────────────┘
```

### Matrice RBAC

| Sujet | Ressource | Verbes autorisés |
|---|---|---|
| `ServiceAccount: app-sa` | `pods` | `get`, `list`, `watch` |
| `ServiceAccount: app-sa` | `services` | `get`, `list` |
| `ServiceAccount: app-sa` | `configmaps` | `get` |
| Tout autre sujet | `pods` | `delete` → **refusé** |

---

## 2. Phase 1 — Cluster Kapsule et accès

**Capture 1 — kubectl get nodes**

![Capture 1](Captures/Phase1/capture1_kubectl_get_nodes.png)

Le cluster `kapsule-gGODON-DAUVEL` a été provisionné sur Scaleway via le CLI :

```bash
scw k8s cluster create \
  name=kapsule-gGODON-DAUVEL \
  version=latest \
  cni=cilium \
  pools.0.size=2 \
  pools.0.node-type=DEV1-M \
  pools.0.name=default
```

Le kubeconfig a été récupéré et exporté :

```bash
scw k8s kubeconfig get <cluster-id> > kubeconfig.yaml
export KUBECONFIG=kubeconfig.yaml
```

La commande `kubectl get nodes` liste les deux nœuds du pool `default` avec le statut **Ready**, prouvant que le cluster est opérationnel et accessible.

---

## 3. Phase 2 — Packaging Helm

**Capture 2 — helm list et pods Running**

![Capture 2](Captures/Phase2/capture2_helm_list_pods_running.png)

Le chart Helm a été initialisé puis adapté aux quatre services de l'application :

```bash
helm create chart
helm install app ./chart -f chart/values-staging.yaml \
  --namespace ggodon-dauvel \
  --create-namespace
```

La commande `helm list` montre la release `app` déployée avec le statut **deployed**. Les pods sont tous au statut **Running** dans le namespace `ggodon-dauvel`.

Le chart expose deux fichiers de valeurs distincts :

**`values-staging.yaml`** — environnement de staging :
```yaml
api:
  replicas: 1
  image:
    repository: 51.15.211.47:5050/root/tp1-ggodon-dauvel/api
    tag: latest
  resources:
    limits:
      cpu: 500m
      memory: 256Mi
    requests:
      cpu: 100m
      memory: 128Mi

db:
  image: postgres:16
  storage: 1Gi

cache:
  image: redis:7
```

**`values-prod.yaml`** — environnement de production :
```yaml
api:
  replicas: 2
  resources:
    limits:
      cpu: 1000m
      memory: 512Mi
    requests:
      cpu: 250m
      memory: 256Mi

db:
  storage: 5Gi
```

> **Principe clé :** aucune valeur n'est codée en dur dans les templates — tout est paramétré via `{{ .Values.* }}`. Cela permet de déployer sur n'importe quel environnement avec un seul `helm install -f values-<env>.yaml`.

---

## 4. Phase 3 — Ingress et probes

**Capture 3 — Application accessible via l'ingress**

![Capture 3](Captures/Phase3/capture3_application_ingress.png)

Le contrôleur ingress-nginx a été installé via Helm :

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

Une ressource Ingress expose le service `api` :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-ingress
  namespace: ggodon-dauvel
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  number: 8000
```

Des probes ont été ajoutées au déploiement de l'API pour fiabiliser son cycle de vie :

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 10
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 8000
  initialDelaySeconds: 5
  periodSeconds: 5
```

La **liveness probe** redémarre le conteneur si l'application est bloquée. La **readiness probe** retire le pod du load balancer si l'application n'est pas prête à recevoir du trafic.

---

## 5. Phase 4 — RBAC

**Capture 4 — Règles RBAC et test d'un accès refusé**

![Capture 4](Captures/Phase4/capture4_rbac_acces_refuse.png)

Un ServiceAccount dédié a été créé avec des droits limités :

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: ggodon-dauvel
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-role
  namespace: ggodon-dauvel
rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-rolebinding
  namespace: ggodon-dauvel
subjects:
  - kind: ServiceAccount
    name: app-sa
    namespace: ggodon-dauvel
roleRef:
  kind: Role
  apiGroupName: rbac.authorization.k8s.io
  name: app-role
```

Le test de permission confirme que l'action non autorisée est refusée :

```bash
# Action autorisée → yes
kubectl auth can-i get pods \
  --as=system:serviceaccount:ggodon-dauvel:app-sa \
  -n ggodon-dauvel

# Action non autorisée → no
kubectl auth can-i delete pods \
  --as=system:serviceaccount:ggodon-dauvel:app-sa \
  -n ggodon-dauvel
```

---

## 6. Phase 5 — NetworkPolicies

**Capture 5 — Trafic bloqué avant, autorisé après**

![Capture 5](Captures/Phase5/capture5_trafic_bloque_puis_autorise.png)

Une politique **deny-all** a d'abord été appliquée pour bloquer tout le trafic par défaut :

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: ggodon-dauvel
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

Puis les flux nécessaires ont été autorisés explicitement :

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-db
  namespace: ggodon-dauvel
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api
      ports:
        - protocol: TCP
          port: 5432
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-to-cache
  namespace: ggodon-dauvel
spec:
  podSelector:
    matchLabels:
      app: cache
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api
      ports:
        - protocol: TCP
          port: 6379
```

> **Sans aucune NetworkPolicy**, tout le trafic est autorisé entre tous les pods — un pod compromis peut atteindre n'importe quel autre service. Avec un **deny-all**, aucun flux n'est autorisé jusqu'à déclaration explicite, appliquant le principe du moindre privilège au niveau réseau.

---

## 7. Phase 6 — Durcissement des pods

**Capture 6 — kubectl describe pod avec le securityContext**

![Capture 6](Captures/Phase6/capture6_kubectl_describe_pod_securitycontext.png)

Un `securityContext` a été ajouté au déploiement de l'API pour réduire la surface d'attaque :

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

Un `ResourceQuota` et un `LimitRange` ont été appliqués au namespace :

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ggodon-dauvel-quota
  namespace: ggodon-dauvel
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: ggodon-dauvel-limitrange
  namespace: ggodon-dauvel
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 128Mi
      defaultRequest:
        cpu: 100m
        memory: 64Mi
```

### Choix de durcissement

| Paramètre | Risque réduit |
|---|---|
| `runAsNonRoot: true` | Empêche un processus compromis d'avoir les droits root dans le conteneur, limitant l'impact d'une exploitation |
| `readOnlyRootFilesystem: true` | Empêche un attaquant d'écrire des fichiers malveillants dans le système de fichiers du conteneur |
| `capabilities: drop: ALL` | Supprime toutes les capacités Linux (NET_ADMIN, SYS_PTRACE, etc.) réduisant drastiquement ce qu'un processus compromis peut faire sur le noyau |
| `allowPrivilegeEscalation: false` | Empêche le processus d'obtenir plus de privilèges que son processus parent via setuid/setgid |

---

## 8. Phase 7 — Admission Kyverno et vérification de signature

**Capture 7 — Image non signée refusée, image signée acceptée**

![Capture 7](Captures/Phase7/capture7_image_non_signee_refusee.png)

Kyverno a été installé via Helm :

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace
```

Une `ClusterPolicy` de vérification de signature a été appliquée en utilisant la clé publique `cosign.pub` du TP3 :

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-api
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "51.15.211.47:5050/root/tp1-ggodon-dauvel/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      <contenu de cosign.pub>
                      -----END PUBLIC KEY-----
```

### Comportement observé

**Image non signée → refusée à l'admission :**
```
Error from server: admission webhook "mutate.kyverno.svc" denied the request:
policy Pod/ggodon-dauvel/test-unsigned-pod for resource violation:
verify-image-signature/verify-api: image verification failed
```

**Image signée (TP3) → acceptée :**
```
pod/api created
```

### Explication de la boucle signature/vérification

```
  TP3 (CI)                              TP4 (Admission)
  ─────────────────────────────────     ──────────────────────────────
  cosign sign → image signée            Kyverno intercepte le Pod
       │                                       │
       ▼                                       ▼
  Signature stockée dans            Vérifie la signature avec
  le registry (OCI)                 cosign.pub versionnée
       │                                       │
       ▼                                       ▼
  cosign.pub versionnée             Admission accordée ou refusée
  dans le dépôt Git                 selon la validité de la signature
```

Le contrôle d'admission **complète** la signature CI en la rendant **obligatoire** : sans Kyverno, un opérateur pourrait déployer n'importe quelle image non signée. Avec Kyverno en mode `Enforce`, seules les images dont la signature est vérifiable avec `cosign.pub` peuvent être déployées dans le cluster.

---

## 9. Mini-questionnaire

### 1. Qu'apporte Helm par rapport à des manifests YAML bruts ?

Helm apporte la **paramétrisation** (une seule source de vérité pour staging et prod via les values), la **gestion du cycle de vie** (install, upgrade, rollback, uninstall en une commande) et la **réutilisabilité** (partage de charts entre équipes). Avec des YAML bruts, tout changement d'environnement implique de dupliquer ou de modifier manuellement chaque fichier, ce qui est source d'erreurs et de désynchronisation.

---

### 2. Différence entre liveness probe et readiness probe

La **liveness probe** détecte si le conteneur est **vivant** — si elle échoue, Kubernetes redémarre le conteneur. Elle sert à sortir d'un état bloqué (deadlock, crash silencieux).

La **readiness probe** détecte si le conteneur est **prêt à recevoir du trafic** — si elle échoue, le pod est retiré du load balancer (endpoints) sans être redémarré. Elle sert à ne pas envoyer de trafic à un pod en cours d'initialisation ou temporairement surchargé.

---

### 3. Sans NetworkPolicy vs avec deny-all

**Sans aucune NetworkPolicy** : tout le trafic est autorisé entre tous les pods de tous les namespaces — un pod compromis peut atteindre librement la base de données, le cache, ou tout autre service du cluster.

**Avec un deny-all** : tout le trafic est bloqué par défaut. Seuls les flux explicitement déclarés dans des NetworkPolicies supplémentaires sont autorisés, appliquant le principe du moindre privilège au niveau réseau.

---

### 4. Deux durcissements securityContext et les risques réduits

**`readOnlyRootFilesystem: true`** : réduit le risque qu'un attaquant ayant compromis le processus puisse écrire des fichiers malveillants (webshell, backdoor) dans le système de fichiers du conteneur ou modifier des binaires existants.

**`capabilities: drop: ALL`** : réduit le risque d'exploitation du noyau Linux — sans capabilities, le processus ne peut pas manipuler les interfaces réseau, charger des modules noyau, accéder à la mémoire d'autres processus ou effectuer des opérations privilégiées qui permettraient une évasion de conteneur.

---

### 5. Comment Kyverno établit-il qu'une image est légitime ?

Kyverno intercepte chaque requête de création de Pod via un webhook d'admission. Pour chaque image référencée, il interroge le registry pour récupérer la signature OCI attachée à l'image (créée par `cosign sign`). Il vérifie cryptographiquement cette signature contre la clé publique déclarée dans la `ClusterPolicy`. Si la signature est absente ou invalide, la requête est rejetée avant que le Pod ne soit créé.

Il vérifie exactement : l'existence d'une signature OCI valide, que cette signature a été produite par le détenteur de la clé privée correspondant à la clé publique configurée, et que le digest de l'image n'a pas changé depuis la signature.

---

### 6. En quoi le contrôle d'admission complète-t-il la signature CI ?

La signature CI (TP3) **garantit l'intégrité et l'origine** de l'image au moment du build — mais elle est passive : rien n'empêche un opérateur de déployer une image non signée ou modifiée directement avec `kubectl`.

Le contrôle d'admission Kyverno (TP4) **rend la signature obligatoire** au moment du déploiement — toute tentative de déployer une image sans signature valide est rejetée par le cluster, indépendamment de qui émet la requête. Les deux mécanismes forment une boucle fermée : la CI produit des artefacts signés, l'admission refuse les artefacts non signés.

---