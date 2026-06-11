# Compte Rendu — TP7 : Infrastructure as Code (plateforme reproductible)
**Mastère Expert IT — CI/CD & DevSecOps**  
**Groupe :** gGODON-DAUVEL  
**Date :** 11 juin 2026  
**Lien GitHub :** [CI-CD_SemaineIntensive](https://github.com/CorentinG21/CI-CD_SemaineIntensive.git)

---

## Table des matières

1. [Architecture de l'infrastructure décrite en code](#1-architecture-de-linfrastructure-décrite-en-code)
2. [Phase 1 — OpenTofu et provider Scaleway](#2-phase-1--opentofu-et-provider-scaleway)
3. [Phase 2 — Provisionner une instance en déclaratif](#3-phase-2--provisionner-une-instance-en-déclaratif)
4. [Phase 3 — State distant et sécurisé](#4-phase-3--state-distant-et-sécurisé)
5. [Phase 4 — Modules et variables](#5-phase-4--modules-et-variables)
6. [Phase 5 — Cluster Kapsule en code](#6-phase-5--cluster-kapsule-en-code)
7. [Phase 6 — Configuration avec Ansible](#7-phase-6--configuration-avec-ansible)
8. [Phase 7 — Destruction et reconstruction](#8-phase-7--destruction-et-reconstruction)
9. [Mini-questionnaire](#9-mini-questionnaire)

---

## 1. Architecture de l'infrastructure décrite en code

### Schéma de l'infrastructure

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │                      Dépôt Git (source de vérité)                    │
  │  providers.tf  ·  main.tf  ·  modules/  ·  playbook.yml              │
  │  *.tfvars.example (sans secrets)  ·  .gitignore (state + secrets)    │
  └──────────────────────────────────┬───────────────────────────────────┘
                                     │  tofu plan / tofu apply
                                     ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │                         OpenTofu (IaC engine)                        │
  │                                                                      │
  │  ┌─────────────────────────┐   ┌────────────────────────────────┐    │
  │  │   Provider Scaleway     │   │   State Backend (Object S3)    │    │
  │  │  (SCW_ACCESS_KEY, etc.) │   │   tfstate-iac-ggodon-dauvel    │    │
  │  └────────────┬────────────┘   └────────────────────────────────┘    │
  │               │ provisionne                                          │
  │               ▼                                                      │
  │  ┌────────────────────────────────────────────────────────────────┐  │
  │  │                  Scaleway (cloud provider)                     │  │
  │  │                                                                │  │
  │  │   Instance iac-ggodon-dauvel          Cluster Kapsule          │  │
  │  │   (ubuntu_jammy, DEV1-S)              kapsule-iac-ggodon-dauvel│  │
  │  │   IP publique routed_ipv4             2 nœuds DEV1-M, CNI Cilium│  │
  │  │   SG: ports 22/80/443                 kubeconfig (sensitive)   │  │
  │  │           │                                                    │  │
  │  │     module "staging"     module "prod"                         │  │
  │  │     (DEV1-M)             (DEV1-S)                              │  │
  │  └────────────┬───────────────────────────────────────────────────┘  │
  └───────────────┼──────────────────────────────────────────────────────┘
                  │  ansible-playbook (SSH, port 22)
                  ▼
  ┌──────────────────────────────────────────────────────────────────────┐
  │                Ansible (configuration management)                    │
  │  playbook.yml  →  Docker installé  ·  Runner GitLab installé         │
  │  Idempotent : 2e passage → changed=0                                 │
  └──────────────────────────────────────────────────────────────────────┘
```

### Rôle du state et stratégie de stockage retenue

Le **state** OpenTofu/Terraform est un fichier JSON (`terraform.tfstate`) qui représente la correspondance entre les ressources déclarées dans le code et les ressources réelles dans le cloud. Il contient les identifiants Scaleway, les IPs, les métadonnées — éventuellement des secrets en clair. Sans state, OpenTofu ne peut pas calculer le diff (`plan`) entre ce qui existe et ce qui est demandé.

La stratégie retenue est un **backend S3 distant** sur Object Storage Scaleway (`tfstate-iac-ggodon-dauvel`). Ce choix répond à trois contraintes :

| Contrainte | Backend local | Backend S3 distant |
|---|---|---|
| Travail en équipe | Impossible (conflits, désynchronisation) | Un seul state partagé |
| Sécurité | Risque de commit accidentel dans Git | Hors du dépôt, accès contrôlé par IAM |
| Reprise après incident | State perdu si poste perdu | Répliqué côté Scaleway |

Le state n'est **jamais** committé dans Git (`.gitignore` : `*.tfstate*`).

### Structure des modules et paramétrage par environnement

Le module `modules/app-instance/` expose des **variables d'entrée** (`name`, `instance_type`, `ports`) et des **outputs** (`ip_address`, `server_id`). L'instanciation pour staging et prod ne differ que par les valeurs passées — jamais par une logique interne au module. Ce principe est identique aux `values.yaml` Helm du TP4 et aux overrides Compose du TP2 : un socle commun, des écarts déclarés à la frontière.

### Séparation provisioning (OpenTofu) / configuration (Ansible)

| Outil | Périmètre | Résultat attendu |
|---|---|---|
| OpenTofu | Création et cycle de vie des **ressources cloud** (instances, réseau, cluster) | Infrastructure existante, adressable |
| Ansible | **Configuration logicielle** sur les machines existantes (paquets, services, fichiers) | Machine dans l'état applicatif voulu |

Les deux phases sont découplées : OpenTofu produit l'IP via un output, Ansible la consomme comme inventaire. Ce couplage minimal permet de remplacer l'un sans toucher à l'autre.

### En quoi l'IaC répond au problème des « flocons de neige »

Un serveur « flocon de neige » est une machine qui a divergé de son état d'origine à force de modifications manuelles — SSH, corrections ad hoc, paquets installés à la main. Son comportement est unique, son contenu inconnu, sa reconstruction impossible à reproduire exactement. C'est précisément l'instance GitLab montée manuellement au TP1.

L'IaC répond à ce problème en rendant l'infrastructure **déclarative, versionnée et reconstructible** :
- Toute modification passe par un commit Git — l'historique est l'audit trail.
- `tofu apply` converge toujours vers le même état quelle que soit la machine de départ.
- `tofu destroy && tofu apply` recrée l'infrastructure à l'identique en quelques minutes.
- Ansible garantit que la configuration logicielle est idempotente : rejouer le playbook ne brise rien.

---

## 2. Phase 1 — OpenTofu et provider Scaleway

**Capture 1 — `tofu init` réussi avec le provider Scaleway**

![Capture 1](Captures/Phase1/capture1_tofu_init.png)

Le projet OpenTofu a été initialisé en déclarant le provider Scaleway dans `providers.tf`. Les credentials ne sont jamais écrits dans les fichiers `.tf` : ils sont injectés par variables d'environnement avant chaque session.

```hcl
# providers.tf
terraform {
  required_providers {
    scaleway = { source = "scaleway/scaleway" }
  }
}

provider "scaleway" {
  zone   = "fr-par-1"
  region = "fr-par"
}
```

```bash
export SCW_ACCESS_KEY="SCWXXXXXXXXXXXXXXXXX"       # jamais committé
export SCW_SECRET_KEY="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export SCW_DEFAULT_PROJECT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

tofu init
```

`tofu init` télécharge le provider Scaleway depuis le registre public et initialise le répertoire `.terraform/`. Le fichier `.gitignore` a été complété pour exclure ce dossier ainsi que les fichiers d'état :

```
.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
```

**Point de contrôle :** `tofu version` et `tofu init` aboutissent ; le provider Scaleway est téléchargé.

---

## 3. Phase 2 — Provisionner une instance en déclaratif

**Capture 2 — `tofu plan` (diff) puis instance créée visible dans la console**

![Capture 2](Captures/Phase2/capture2_tofu_plan_apply.png)

L'instance TP1 a été recréée en code déclaratif. Trois ressources sont nécessaires : un groupe de sécurité, une IP publique explicite, et l'instance elle-même.

```hcl
resource "scaleway_instance_security_group" "web" {
  name                    = "sg-iac-ggodon-dauvel"
  inbound_default_policy  = "drop"

  dynamic "inbound_rule" {
    for_each = [22, 80, 443]
    content {
      action = "accept"
      port   = inbound_rule.value
    }
  }
}

# L'IP publique doit être créée explicitement —
# sans elle l'instance est injoignable (pas de SSH pour Ansible).
resource "scaleway_instance_ip" "public" {
  type = "routed_ipv4"
}

resource "scaleway_instance_server" "app" {
  name              = "iac-ggodon-dauvel"
  type              = "DEV1-S"
  image             = "ubuntu_jammy"
  ip_id             = scaleway_instance_ip.public.id
  security_group_id = scaleway_instance_security_group.web.id
}

output "app_ip" {
  value = scaleway_instance_ip.public.address
}
```

```bash
tofu plan    # lit le diff : 3 ressources à créer
tofu apply   # provisionne sur Scaleway
```

`tofu plan` affiche le diff avant toute modification : chaque ressource à créer est préfixée par `+`. Après `apply`, l'instance `iac-ggodon-dauvel` apparaît dans la console Scaleway avec son IP publique affichée en output.

**Point de contrôle :** L'instance est visible dans la console Scaleway avec une IP publique.

> **Piège évité :** Sans la ressource `scaleway_instance_ip` et son `ip_id`, l'instance n'a pas d'IP publique — aucun accès SSH possible, Ansible est bloqué en phase 6. Le state local (`terraform.tfstate`) décrit désormais la réalité : il ne doit jamais être édité à la main.

---

## 4. Phase 3 — State distant et sécurisé

**Capture 3 — State présent dans le bucket Object Storage**

![Capture 3](Captures/Phase3/capture3_state_bucket.png)

Le state a été migré vers un bucket Object Storage Scaleway (compatible S3). Le bucket a d'abord été créé via la console (ou une ressource `scaleway_object_bucket` appliquée avec le backend encore local), puis le bloc `backend "s3"` a été ajouté à `providers.tf`.

```hcl
terraform {
  required_providers {
    scaleway = { source = "scaleway/scaleway" }
  }

  backend "s3" {
    bucket = "tfstate-iac-ggodon-dauvel"
    key    = "platform/terraform.tfstate"
    region = "fr-par"

    endpoints = { s3 = "https://s3.fr-par.scw.cloud" }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    # skip_s3_checksum = true   # à décommenter si erreur de checksum
  }
}
```

```bash
tofu init -migrate-state   # transfère le state local vers le bucket S3
```

**Point de contrôle :** Le fichier `platform/terraform.tfstate` est visible dans le bucket Object Storage ; aucun fichier `.tfstate` n'est présent localement.

> **Pièges évités :**
> - Le bloc `endpoints = { s3 = "..." }` est la syntaxe requise pour OpenTofu ≥ 1.6 ; l'ancien champ `endpoint = "..."` est déprécié et provoque une erreur.
> - `skip_requesting_account_id = true` est indispensable pour un S3 non-AWS.
> - Le backend S3 Scaleway ne fournit pas de verrouillage natif : une discipline d'équipe (un `apply` à la fois) est nécessaire.

---

## 5. Phase 4 — Modules et variables

**Capture 4 — Module instancié pour staging et prod, outputs affichés**

![Capture 4](Captures/Phase4/capture4_modules_outputs.png)

La définition d'instance a été extraite dans un module réutilisable `modules/app-instance/`.

**Structure du module :**

```
modules/
└── app-instance/
    ├── main.tf       # ressources scaleway_instance_*
    ├── variables.tf  # name, instance_type, ports
    └── outputs.tf    # ip_address, server_id
```

```hcl
# modules/app-instance/variables.tf
variable "name" {
  description = "Nom de l'instance"
  type        = string
}

variable "instance_type" {
  description = "Type d'instance Scaleway"
  type        = string
  default     = "DEV1-M"
}

variable "ports" {
  description = "Ports ouverts en inbound"
  type        = list(number)
  default     = [22, 80, 443]
}
```

```hcl
# modules/app-instance/outputs.tf
output "ip" {
  value = scaleway_instance_ip.public.address
}

output "id" {
  value = scaleway_instance_server.app.id
}
```

**Instanciation pour deux environnements :**

```hcl
# main.tf (racine)
module "staging" {
  source        = "./modules/app-instance"
  name          = "staging-iac-ggodon-dauvel"
  instance_type = "DEV1-M"
}

module "prod" {
  source        = "./modules/app-instance"
  name          = "prod-iac-ggodon-dauvel"
  instance_type = "DEV1-S"
}

output "staging_ip" { value = module.staging.ip }
output "prod_ip"    { value = module.prod.ip }
```

**Point de contrôle :** Un même module produit deux environnements distincts ; les outputs IP sont affichés après `tofu apply`.

> **Principe clé :** Le module ne contient aucune valeur en dur spécifique à un environnement — tout passe par les variables. C'est le même principe que les `values.yaml` Helm (TP4) et les overrides Compose (TP2) : un socle commun, des écarts déclarés.

---

## 6. Phase 5 — Cluster Kapsule en code

**Capture 5 — Cluster créé par OpenTofu, `kubectl get nodes` opérationnel**

![Capture 5](Captures/Phase5/capture5_kapsule_nodes.png)

Le cluster Kapsule du TP4 a été reproduit entièrement en code déclaratif. La version Kubernetes est paramétrée par variable pour éviter de figer une version obsolète.

```bash
# Lister les versions disponibles le jour du TP
scw k8s version list
```

```hcl
variable "k8s_version" {
  description = "Version Kapsule supportée — listez-les avec : scw k8s version list"
  type        = string
}

resource "scaleway_k8s_cluster" "main" {
  name                        = "kapsule-iac-ggodon-dauvel"
  version                     = var.k8s_version
  cni                         = "cilium"
  delete_additional_resources = true
}

resource "scaleway_k8s_pool" "default" {
  cluster_id = scaleway_k8s_cluster.main.id
  name       = "default"
  node_type  = "DEV1-M"
  size       = 2
}

output "kubeconfig" {
  value     = scaleway_k8s_cluster.main.kubeconfig[0].config_file
  sensitive = true
}
```

```bash
tofu apply -var="k8s_version=1.35.3"

# Récupérer le kubeconfig et vérifier l'accès
tofu output -raw kubeconfig > kubeconfig.yaml
export KUBECONFIG=kubeconfig.yaml
kubectl get nodes
```

**Point de contrôle :** Le cluster est créé par OpenTofu ; `kubectl get nodes` liste les deux nœuds en état `Ready`.

> **Pièges évités :**
> - Ne pas figer la version Kubernetes en dur : une version trop ancienne n'est plus proposée par Kapsule et le `apply` échoue — vérifier les versions disponibles le jour du TP.
> - Marquer l'output `kubeconfig` comme `sensitive` pour éviter son affichage dans les logs.
> - Le CNI Cilium (cohérent avec le TP4) doit être déclaré à la création ; il ne peut pas être modifié après.

---

## 7. Phase 6 — Configuration avec Ansible

**Capture 6 — Playbook appliqué, puis second run montrant `changed=0`**

![Capture 6](Captures/Phase6/capture6_ansible_idempotent.png)

Ansible configure l'instance provisionnée en phase 2 : Docker et le runner GitLab sont installés de façon idempotente.

```yaml
# playbook.yml
- hosts: app
  become: true
  tasks:
    - name: Installer les dépendances
      apt:
        name:
          - docker.io
          - curl
        update_cache: true

    - name: Démarrer Docker
      service:
        name: docker
        state: started
        enabled: true

    - name: Installer le runner GitLab
      shell: |
        curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
        apt-get install -y gitlab-runner
      args:
        creates: /usr/bin/gitlab-runner   # idempotence : ne s'exécute que si absent
```

```bash
# 1er passage : installation des paquets, changed > 0
ansible-playbook -i "<IP_instance>," -u root playbook.yml

# 2e passage : tout est déjà en place, changed=0
ansible-playbook -i "<IP_instance>," -u root playbook.yml
```

**Point de contrôle :** Le premier passage installe Docker et configure le runner. Le second passage se termine avec `changed=0` — c'est la preuve de l'idempotence.

> **Principe d'idempotence :** Les modules Ansible (`apt`, `service`, `copy`, `template`) vérifient l'état actuel avant d'agir. Si l'état souhaité est déjà atteint, rien n'est exécuté. À l'inverse, les tâches `shell:` ou `command:` s'exécutent à chaque passage sauf si protégées par `creates:` ou `when:`.

---

## 8. Phase 7 — Destruction et reconstruction

**Capture 7 — `destroy` puis `apply` : infrastructure reconstruite à l'identique**

![Capture 7](Captures/Phase7/capture7_destroy_apply.png)

Cette phase est la démonstration finale de la reproductibilité : l'infrastructure est détruite puis recréée à l'identique depuis le code.

```bash
# Destruction de toutes les ressources gérées par OpenTofu
tofu destroy

# Vérification : plus aucune ressource visible dans la console Scaleway
# (instances, cluster, IP, security groups)

# Reconstruction à l'identique depuis le code
tofu apply
```

Après `apply`, les ressources recréées sont strictement identiques à celles de la phase 2 : même nom, même type d'instance, mêmes règles de sécurité, même configuration réseau. L'IP publique peut changer (nouvelle allocation), mais la structure est conforme.

**Point de contrôle :** Après `destroy` puis `apply`, l'infrastructure est reconstruite conforme à sa description dans le code.

> **Pièges évités :**
> - `tofu destroy` détruit réellement : vérifier le périmètre avant d'exécuter (ne pas inclure de ressources partagées avec d'autres TP).
> - Les données non gérées par le code (volumes, contenu applicatif dans l'instance) ne survivent pas à `destroy` — c'est l'intérêt de séparer données et infrastructure dans deux stacks distinctes.

---

## 9. Mini-questionnaire

### 1. Qu'est-ce que le state d'OpenTofu/Terraform et pourquoi ne jamais le committer ?

Le **state** est le fichier (`terraform.tfstate`) qui mappe les ressources déclarées dans le code aux ressources réelles dans le cloud. Il stocke les identifiants, IPs, attributs et dépendances de chaque ressource. Sans state, OpenTofu ne peut pas calculer le diff (`plan`) et ne sait pas quelles ressources existent déjà.

Il ne doit **jamais** être committé pour deux raisons :
1. **Sécurité** : il peut contenir des valeurs sensibles en clair (mots de passe, clés API, tokens) issus des outputs ou des attributs de ressources.
2. **Cohérence** : en équipe, chaque développeur aurait une version du state différente, provoquant des conflits et des doubles créations de ressources. Le backend distant est la solution canonique.

---

### 2. `plan` et `apply` : à quoi sert l'étape `plan` ?

`tofu plan` calcule et affiche le **diff** entre l'état actuel (tel que décrit dans le state) et l'état souhaité (tel que décrit dans les fichiers `.tf`). Il liste les ressources à créer (`+`), modifier (`~`) ou détruire (`-`), sans effectuer aucune modification réelle.

`plan` est une étape de **validation et de revue** avant action. Elle permet :
- De détecter les effets de bord inattendus (ex. une modification qui force le remplacement d'une ressource).
- D'obtenir une approbation humaine avant d'impacter le cloud.
- De servir de plan d'exécution exact que `apply` peut rejouer de manière déterministe.

Lire le plan avant tout `apply` est une règle d'hygiène fondamentale en IaC.

---

### 3. Qu'est-ce que l'idempotence et comment Ansible la garantit-il ?

L'**idempotence** signifie qu'appliquer une opération plusieurs fois produit exactement le même résultat que l'appliquer une fois. En configuration, cela signifie : rejouer un playbook sur une machine déjà configurée ne modifie rien et ne brise rien.

Ansible garantit l'idempotence via ses **modules** (`apt`, `service`, `copy`, `file`, `template`…) : chaque module commence par lire l'état actuel du système. Si l'état cible est déjà atteint, le module rapporte `ok` et n'exécute rien. Seules les tâches `shell:` ou `command:` brutes ne sont pas idempotentes par défaut — elles doivent être protégées par `creates:`, `when:` ou `changed_when: false`.

L'idempotence est la propriété clé qui permet d'utiliser Ansible comme outil de remédiation : on peut rejouer le playbook à tout moment pour s'assurer qu'une machine est dans l'état attendu.

---

### 4. Provisioning (OpenTofu) et configuration (Ansible) : quelle différence et pourquoi les séparer ?

| Dimension | Provisioning (OpenTofu) | Configuration (Ansible) |
|---|---|---|
| **Quoi** | Créer et gérer les ressources cloud (instances, réseaux, cluster, buckets) | Installer et paramétrer les logiciels sur les machines existantes |
| **Cycle de vie** | Lié à l'existence de la ressource (`create`/`destroy`) | Lié à l'état logiciel (peut être rejoué à tout moment) |
| **Interface** | API cloud (Scaleway, AWS…) | SSH sur les machines |
| **Résultat** | Infrastructure adressable avec une IP/endpoint | Machine dans l'état applicatif voulu |

Les séparer apporte trois bénéfices :
1. **Clarté des responsabilités** : OpenTofu ne sait pas ce qui tourne dans la machine ; Ansible ne sait pas comment la machine a été créée.
2. **Découplage** : on peut reconfigurer une machine sans la recréer, ou recréer l'infrastructure en réappliquant ensuite le même playbook.
3. **Testabilité** : on peut tester le playbook Ansible sur n'importe quelle machine Ubuntu, indépendamment de Scaleway.

---

### 5. Pourquoi un backend distant pour le state plutôt qu'un fichier local ?

Un state local est problématique à trois niveaux :

| Problème | State local | Backend S3 distant |
|---|---|---|
| **Travail en équipe** | Chaque développeur a sa propre version → conflits, doubles créations | Un seul state partagé, toujours à jour |
| **Sécurité** | Risque de commit accidentel dans Git (clés, IPs, mots de passe) | Stocké hors du dépôt, accès contrôlé par IAM Scaleway |
| **Résilience** | Perte du state si poste perdu → impossible de gérer les ressources existantes | Répliqué et versionnné côté Scaleway |

Le backend S3 distant (Object Storage Scaleway) est la solution canonique en équipe : il centralise le state, l'isole du dépôt Git et le rend accessible à tous les membres autorisés — ou à la pipeline CI/CD lors d'un `apply` automatisé.

---

### 6. En quoi l'infrastructure as code répond-elle au problème des serveurs « flocons de neige » ?

Un serveur **flocon de neige** est une machine qui a divergé de son état initial à force de modifications manuelles : paquets installés en SSH, configurations corrigées à la main, services démarrés sans documentation. Sa configuration réelle n'est connue que de la personne qui l'a créée. Elle est impossible à reproduire exactement — c'est l'instance GitLab du TP1.

L'IaC résout ce problème sur trois axes :

1. **Déclaratif** : l'état souhaité est décrit dans des fichiers versionnnés dans Git. Il n'existe qu'une seule source de vérité.
2. **Idempotent** : `tofu apply` et `ansible-playbook` convergent toujours vers le même état, quelle que soit la machine de départ. Aucune dérive n'est possible si tout passe par le code.
3. **Reconstructible** : `tofu destroy && tofu apply` + rejeu du playbook Ansible recrée l'infrastructure à l'identique en quelques minutes. Le TP7 en fait la démonstration par l'acte (phase 7).

La phrase clé du cours se vérifie ici : **une infrastructure relue, versionnée et reconstructible n'est plus un flocon de neige**.

---

### 7. Terraform et OpenTofu : qu'est-ce qui a motivé le fork ?

En août 2023, HashiCorp a changé la licence de Terraform de la **Mozilla Public License 2.0 (MPL 2.0)** — une licence open source — vers la **Business Source License 1.1 (BSL)**, qui restreint l'utilisation commerciale de Terraform par des concurrents de HashiCorp.

Cette décision a provoqué la création d'**OpenTofu**, fork communautaire maintenu par la **Linux Foundation** sous licence MPL 2.0. Les motivations principales du fork :

- **Neutralité** : OpenTofu est gouverné par la communauté, sans dépendance à un éditeur propriétaire.
- **Compatibilité ascendante** : OpenTofu est un remplacement drop-in de Terraform — mêmes fichiers `.tf`, même syntaxe HCL, même CLI (`tofu` en lieu et place de `terraform`).
- **Pérennité** : les entreprises utilisant Terraform dans des produits commerciaux risquaient des poursuites sous BSL ; OpenTofu est sous licence libre sans ambiguïté.

OpenTofu a depuis publié ses propres fonctionnalités (state encryption, nouvelles fonctions HCL) et est recommandé dans le contexte de ce TP comme alternative entièrement libre.
