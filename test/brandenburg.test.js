import test from "node:test";
import assert from "node:assert/strict";

import {
  normalizeXPlanProperties,
  buildWfsGetFeatureUrl,
  addLocationMarker,
  addBPlanGeoJson
} from "../src/brandenburg/index.js";

test("normalizes XPlan GRZ/GFZ values", () => {
  assert.deepEqual(
    normalizeXPlanProperties({ GRZ: "0,4", GFZ: "0.8", GFZmax: 1.2 }),
    {
      grz: 0.4,
      grzMin: null,
      grzMax: null,
      gfz: 0.8,
      gfzMin: null,
      gfzMax: 1.2,
      name: null,
      rechtsstand: null,
      artDerBaulNutzung: null
    }
  );
});

test("builds a WFS 2.0 GetFeature point bbox request", () => {
  const url = buildWfsGetFeatureUrl({
    wfsUrl: "https://example.test/wfs",
    typeNames: "xplan:BP_BaugebietsTeilFlaeche",
    lon: 13.0645,
    lat: 52.3906
  });

  assert.equal(url.searchParams.get("service"), "WFS");
  assert.equal(url.searchParams.get("version"), "2.0.0");
  assert.equal(url.searchParams.get("request"), "GetFeature");
  assert.equal(url.searchParams.get("typeNames"), "xplan:BP_BaugebietsTeilFlaeche");
  assert.match(url.searchParams.get("bbox"), /EPSG:4326$/);
});

test("adapts marker and GeoJSON calls to MpJsApi", () => {
  const calls = [];
  const api = {
    addMarker: (...args) => calls.push(["marker", ...args]),
    addGeoJSONLayer: (...args) => calls.push(["geojson", ...args])
  };

  addLocationMarker({ lon: 13, lat: 52, api });
  addBPlanGeoJson({ type: "FeatureCollection", features: [] }, { api });

  assert.equal(calls[0][0], "marker");
  assert.deepEqual(calls[0][1], [13, 52]);
  assert.equal(calls[1][0], "geojson");
});
