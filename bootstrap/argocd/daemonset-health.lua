-- Argo CD health check for DaemonSets (argocd-cm key
-- resource.customizations.health.apps_DaemonSet), set by homelabCD.
--
-- The built-in check waits for a pod on every node. A pod on a node that is
-- down never becomes ready, so a DaemonSet stays "Progressing" and every
-- sync of its app (e.g. Longhorn) waits behind it, so nothing else in that
-- app is updated. Here a DaemonSet is Healthy once more than half of its
-- pods are updated and available; the message says how many are missing.
hs = {}
local s = obj.status
if s == nil or (obj.metadata.generation ~= nil and s.observedGeneration ~= nil
    and obj.metadata.generation > s.observedGeneration) then
  hs.status = "Progressing"
  hs.message = "Waiting for the DaemonSet controller"
  return hs
end
local desired = s.desiredNumberScheduled or 0
local updated = s.updatedNumberScheduled or 0
local available = s.numberAvailable or 0
if obj.spec ~= nil and obj.spec.updateStrategy ~= nil
    and obj.spec.updateStrategy.type == "OnDelete" then
  updated = desired
end
if updated >= desired and available >= desired then
  hs.status = "Healthy"
  hs.message = string.format("%d of %d pods available", available, desired)
elseif updated * 2 > desired and available * 2 > desired then
  hs.status = "Healthy"
  hs.message = string.format(
    "%d of %d pods available; the others are on nodes that are down or still starting",
    math.min(available, updated), desired)
else
  hs.status = "Progressing"
  hs.message = string.format("%d of %d pods updated, %d available", updated, desired, available)
end
return hs
