# SIS Platform

Integration workspace for SIS Platform.

## BrandenburgVIEWER / B-Plan

The connector in `src/brandenburg/` provides:

1. **XPlan normalization** for `GRZ`, `GRZmin`, `GRZmax`, `GFZ`, `GFZmin`, and `GFZmax`.
2. **Generic WFS 2.0 / GeoJSON point queries** for Brandenburg municipal B-Plan services.
3. **Brandenburg Kartenviewer adapter** for `window.MpJsApi`.
4. **A concrete near-Berlin source:** Teltow B-Plan B-27a "Komponistenviertel" using the city's WFS 1.1/GML service for structured metrics and WMS for map display.

### Near-Berlin example: Teltow B-27a

```js
import {
  fetchTeltowB27aMetricsAtPoint,
  waitForMpJsApi,
  addLocationMarker,
  showTeltowB27aInViewer
} from "./src/brandenburg/index.js";

// Use coordinates for a property inside the B-27a plan area.
const lon = 13.289;
const lat = 52.389;

const result = await fetchTeltowB27aMetricsAtPoint({ lon, lat });

console.log({
  grz: result.plan?.grz,
  gfz: result.plan?.gfz,
  grzMin: result.plan?.grzMin,
  grzMax: result.plan?.grzMax,
  gfzMin: result.plan?.gfzMin,
  gfzMax: result.plan?.gfzMax
});

const api = await waitForMpJsApi();
addLocationMarker({ lon, lat, api, label: "Teltow B-27a" });
showTeltowB27aInViewer({ api });
```

### Generic GeoJSON WFS example

```js
import {
  fetchFirstBPlanWithMetrics,
  waitForMpJsApi,
  addLocationMarker,
  addBPlanGeoJson
} from "./src/brandenburg/index.js";

const lon = 13.0645;
const lat = 52.3906;

const result = await fetchFirstBPlanWithMetrics({
  wfsUrl: process.env.BB_BPLAN_WFS_URL,
  typeNames: process.env.BB_BPLAN_TYPENAME ?? "xplan:BP_BaugebietsTeilFlaeche",
  lon,
  lat
});

const api = await waitForMpJsApi();
addLocationMarker({ lon, lat, api });
addBPlanGeoJson(result.geojson, { api });
```

### Tests

```bash
npm test
```

No runtime dependencies are required.
