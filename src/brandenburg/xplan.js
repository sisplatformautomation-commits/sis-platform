const KEY_ALIASES = {
  grz: ["GRZ", "grz", "xplan:GRZ"],
  grzMin: ["GRZmin", "grzmin", "grzMin", "xplan:GRZmin"],
  grzMax: ["GRZmax", "grzmax", "grzMax", "xplan:GRZmax"],
  gfz: ["GFZ", "gfz", "xplan:GFZ"],
  gfzMin: ["GFZmin", "gfzmin", "gfzMin", "xplan:GFZmin"],
  gfzMax: ["GFZmax", "gfzmax", "gfzMax", "xplan:GFZmax"],
  name: ["name", "planName", "bezeichnung", "xplan:name"],
  rechtsstand: ["rechtsstand", "xplan:rechtsstand"],
  artDerBaulNutzung: ["allgArtDerBaulNutzung", "besondereArtDerBaulNutzung", "artDerBaulNutzung"]
};

function pick(properties, aliases) {
  for (const key of aliases) {
    if (properties[key] !== undefined && properties[key] !== null && properties[key] !== "") {
      return properties[key];
    }
  }
  return undefined;
}

function numberOrNull(value) {
  if (value === undefined || value === null || value === "") return null;
  const normalized = typeof value === "string" ? value.replace(",", ".") : value;
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : null;
}

export function normalizeXPlanProperties(properties = {}) {
  return {
    grz: numberOrNull(pick(properties, KEY_ALIASES.grz)),
    grzMin: numberOrNull(pick(properties, KEY_ALIASES.grzMin)),
    grzMax: numberOrNull(pick(properties, KEY_ALIASES.grzMax)),
    gfz: numberOrNull(pick(properties, KEY_ALIASES.gfz)),
    gfzMin: numberOrNull(pick(properties, KEY_ALIASES.gfzMin)),
    gfzMax: numberOrNull(pick(properties, KEY_ALIASES.gfzMax)),
    name: pick(properties, KEY_ALIASES.name) ?? null,
    rechtsstand: pick(properties, KEY_ALIASES.rechtsstand) ?? null,
    artDerBaulNutzung: pick(properties, KEY_ALIASES.artDerBaulNutzung) ?? null
  };
}

export function summarizeBPlanFeature(feature) {
  if (!feature || feature.type !== "Feature") {
    throw new TypeError("Expected a GeoJSON Feature");
  }

  const normalized = normalizeXPlanProperties(feature.properties ?? {});
  return {
    id: feature.id ?? null,
    ...normalized,
    geometry: feature.geometry ?? null,
    rawProperties: feature.properties ?? {}
  };
}

export function hasStructuredBuildingMetrics(feature) {
  const item = summarizeBPlanFeature(feature);
  return [item.grz, item.grzMin, item.grzMax, item.gfz, item.gfzMin, item.gfzMax]
    .some((value) => value !== null);
}
