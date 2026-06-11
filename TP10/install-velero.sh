#!/bin/bash
# Installation de Velero - TP10 gGODON-DAUVEL
# Prérequis : kubectl configuré, credentials-velero présent

# Téléchargement et installation du binaire
wget https://github.com/vmware-tanzu/velero/releases/download/v1.13.0/velero-v1.13.0-linux-amd64.tar.gz
tar -xvf velero-v1.13.0-linux-amd64.tar.gz
sudo mv velero-v1.13.0-linux-amd64/velero /usr/local/bin/

# Installation sur le cluster Kapsule
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket backup-ggodon-dauvel \
  --secret-file ./credentials-velero \
  --backup-location-config region=fr-par,s3ForcePathStyle=true,s3Url=https://s3.fr-par.scw.cloud \
  --use-node-agent

# Vérification
velero backup-location get