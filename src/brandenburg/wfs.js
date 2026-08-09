import { summarizeBPlanFeature } from "./xplan.js";

export function buildWfsGetFeatureUrl({
  wfsUrl,
  typeNames,
  lon,
  lat,
  srsName = "EPSG:4326",
  count = 20,
  outputFormat = "application/json"
}) {
  if (!wfsUrl) throw new TypeError("wfsUrl is required");
  if (!typeNames) throw new TypeError("typeNames is required");
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    throw new TypeError("lon and lat must be finite numbers");
  }

  const url = new URL(wfsUrl);
  url.searchParams.set("service", "WFS");
  url.searchParams.set("version", "2.0.0");
  url.searchParams.set("request", "GetFeature");
  url.searchParams.set("typeNames", typeNames);
  url.searchParams.set("srsName", srsName);
  url.searchParams.set("count", String(count));
  url.searchParams.set("outputFormat", outputFormat);

  // A very small bbox avoids relying on vendor-specific CQL filters and works with WFS 2.0.
  const delta = 0.00001;
  url.searchParams.set(
    "bbox",
    `${lon - delta},${lat - delta},${lon + delta},${lat + delta},${srsName}`
  );

  return url;
}

export async function fetchBPlanAtPoint({ fetchImpl = fetch, ...options }) {
  const url = buildWfsGetFeatureUrl(options);
  const response = await fetchImpl(url, {
    headers: {
      Accept: "application/geo+json, application/json;q=0.9"
    }
  });

  if (!response.ok) {
    throw new Error(`B-Plan WFS request failed: ${response.status} ${response.statusText}`);
  }

  const geojson = await response.json();
  const features = Array.isArray(geojson.features) ? geojson.features : [];

  return {
    requestUrl: url.toString(),
    geojson,
    plans: features.map(summarizeBPlanFeature)
  };
}

export async function fetchFirstBPlanWithMetrics(options) {
  const result = await fetchBPlanAtPoint(options);
  const plan = result.plans.find((candidate) =>
    [candidate.grz, candidate.grzMin, candidate.grzMax, candidate.gfz, candidate.gfzMin, candidate.gfzMax]
      .some((value) => value !== null)
  ) ?? result.plans[0] ?? null;

  return { ...result, plan };
}
