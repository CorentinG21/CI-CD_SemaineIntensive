#!/bin/bash
# Sauvegarde des ressources Kubernetes - TP10 gGODON-DAUVEL

# Sauvegarde des ressources uniquement
velero backup create app-ggodon-dauvel \
  --include-namespaces ggodon-dauvel

# Sauvegarde avec volumes
velero backup create app-ggodon-dauvel-data \
  --include-namespaces ggodon-dauvel \
  --default-volumes-to-fs-backup

# Vérification
velero backup get
velero backup describe app-ggodon-dauvel-data --details