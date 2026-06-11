#!/bin/bash
# Procédure de restauration - TP10 gGODON-DAUVEL

# Restauration normale (même namespace)
# velero restore create --from-backup app-ggodon-dauvel

# Restauration sinistre (namespace neuf)
velero restore create sinistre-ggodon-dauvel \
  --from-backup app-ggodon-dauvel \
  --namespace-mappings ggodon-dauvel:ggodon-dauvel-restore

# Vérification
velero restore get
kubectl get pods -n ggodon-dauvel-restore