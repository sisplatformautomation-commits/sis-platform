import { normalizeXPlanProperties } from "./xplan.js";

export const TELTOW_B27A = Object.freeze({
  id: "teltow-b27a",
  title: "Bebauungsplan Nr. B-27a Komponistenviertel - Stadt Teltow",
  wfsUrl: "https://www.geoportal-teltow.de/isk/telt_bp23",
  wfsVersion: "1.1.0",
  typeName: "ms:bp_baugebietsteilflaeche",
  srsName: "EPSG:4326",
  wmsUrl: "https://www.geoportal-teltow.de/isk/telt_bp23",
  wmsLayers: "raster,bp_plan,bp_baugebietsteilflaeche",
  envelopeWgs84: [13.276, 52.3827, 13.3012, 52.3966]
});

function decodeXmlEntities(value) {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'");
}

function hasMetrics(plan) {
  return [plan.grz, plan.grzMin, plan.grzMax, plan.gfz, plan.gfzMin, plan.gfzMax]
    .some((value) => value !== null);
}

export function buildTeltowB27aWfsUrl({ lon, lat, delta = 0.00005 } = {}) {
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    throw new TypeError("lon and lat must be finite numbers");
  }

  const url = new URL(TELTOW_B27A.wfsUrl);
  url.searchParams.set("service", "WFS");
  url.searchParams.set("version", TELTOW_B27A.wfsVersion);
  url.searchParams.set("request", "GetFeature");
  url.searchParams.set("typeName", TELTOW_B27A.typeName);
  url.searchParams.set("srsName", TELTOW_B27A.srsName);
  url.searchParams.set("maxFeatures", "20");
  url.searchParams.set("outputFormat", "text/xml; subtype=gml/3.1.1");

  // WFS 1.1 with EPSG:4326 uses the CRS axis order (lat, lon).
  url.searchParams.set(
    "bbox",
    `${lat - delta},${lon - delta},${lat + delta},${lon + delta},${TELTOW_B27A.srsName}`
  );

  return url;
}

export function parseTeltowB27aGml(xml) {
  if (typeof xml !== "string") throw new TypeError("xml must be a string");
  if (/ExceptionReport|ServiceException/i.test(xml)) {
    throw new Error("Teltow WFS returned an exception document");
  }

  const plans = [];
  const featurePattern = /<(?:[\w.-]+:)?bp_baugebietsteilflaeche\b([^>]*)>([\s\S]*?)<\/(?:[\w.-]+:)?bp_baugebietsteilflaeche>/gi;
  let featureMatch;

  while ((featureMatch = featurePattern.exec(xml)) !== null) {
    const [, attributes, body] = featureMatch;
    const id = /\bgml:id=["']([^"']+)["']/i.exec(attributes)?.[1] ?? null;
    const properties = {};
    const propertyPattern = /<(?:[\w.-]+:)?([A-Za-z_][\w.-]*)\b[^>]*>\s*([^<>]*?)\s*<\/(?:[\w.-]+:)?\1>/gi;
    let propertyMatch;

    while ((propertyMatch = propertyPattern.exec(body)) !== null) {
      const value = decodeXmlEntities(propertyMatch[2].trim());
      if (value !== "") properties[propertyMatch[1]] = value;
    }

    plans.push({
      id,
      ...normalizeXPlanProperties(properties),
      rawProperties: properties
    });
  }

  return plans;
}

export async function fetchTeltowB27aMetricsAtPoint({ lon, lat, fetchImpl = fetch, delta } = {}) {
  const url = buildTeltowB27aWfsUrl({ lon, lat, delta });
  const response = await fetchImpl(url, {
    headers: { Accept: "application/gml+xml, text/xml;q=0.9" }
  });

  if (!response.ok) {
    throw new Error(`Teltow B-Plan WFS request failed: ${response.status} ${response.statusText}`);
  }

  const xml = await response.text();
  const plans = parseTeltowB27aGml(xml);
  const plan = plans.find(hasMetrics) ?? plans[0] ?? null;

  return {
    source: TELTOW_B27A,
    requestUrl: url.toString(),
    plans,
    plan
  };
}

export function buildTeltowB27aViewerConfig({ opacity = 0.72 } = {}) {
  return {
    layers: [{
      uuid: "sis-teltow-b27a",
      url: TELTOW_B27A.wmsUrl,
      layers: TELTOW_B27A.wmsLayers,
      title: TELTOW_B27A.title,
      transparent: true,
      opacity,
      visible: true
    }]
  };
}

export function showTeltowB27aInViewer({ api = globalThis.MpJsApi, opacity } = {}) {
  if (!api?.applyThemedMap) {
    throw new Error("MpJsApi.applyThemedMap is not available");
  }
  return api.applyThemedMap(buildTeltowB27aViewerConfig({ opacity }));
}
