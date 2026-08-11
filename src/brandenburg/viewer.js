function getApi(api) {
  const resolved = api ?? globalThis.MpJsApi;
  if (!resolved) {
    throw new Error("MpJsApi is not available. Wait for the Brandenburg viewer API to be ready first.");
  }
  return resolved;
}

export function addLocationMarker({ lon, lat, label = "SIS Grundstück", api } = {}) {
  if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
    throw new TypeError("lon and lat must be finite numbers");
  }

  return getApi(api).addMarker([lon, lat], {
    id: `sis-${lon}-${lat}`,
    address: label
  });
}

export function addBPlanGeoJson(geojson, { api, layerName = "Bebauungsplan" } = {}) {
  if (!geojson || geojson.type !== "FeatureCollection") {
    throw new TypeError("Expected a GeoJSON FeatureCollection");
  }

  return getApi(api).addGeoJSONLayer(geojson, {
    layerName,
    popupEventMode: "click",
    showInLayerTree: true
  });
}

export function waitForMpJsApi({ timeoutMs = 15000, windowObject = globalThis } = {}) {
  if (windowObject.MpJsApi) return Promise.resolve(windowObject.MpJsApi);

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("Timed out waiting for MpJsApi"));
    }, timeoutMs);

    const onReady = () => {
      if (!windowObject.MpJsApi) return;
      cleanup();
      resolve(windowObject.MpJsApi);
    };

    const cleanup = () => {
      clearTimeout(timeout);
      windowObject.removeEventListener?.("mpjsapi-ready", onReady);
    };

    windowObject.addEventListener?.("mpjsapi-ready", onReady);
  });
}
