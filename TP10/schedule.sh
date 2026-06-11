#!/bin/bash
# Planification automatique - TP10 gGODON-DAUVEL

# Sauvegarde quotidienne à 2h du matin, rétention 7 jours
velero schedule create quotidien-ggodon-dauvel \
  --schedule="0 2 * * *" \
  --include-namespaces ggodon-dauvel \
  --ttl 168h0m0s

# Vérification
velero schedule get