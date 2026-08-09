# SIS Platform

Integration workspace for SIS Platform.

## BrandenburgVIEWER / B-Plan

The first connector lives in `src/brandenburg/` and provides three pieces:

1. **XPlan normalization** for `GRZ`, `GRZmin`, `GRZmax`, `GFZ`, `GFZmin`, and `GFZmax`.
2. **WFS 2.0 point queries** for municipal/Brandenburg B-Plan services that can return GeoJSON.
3. **Brandenburg Kartenviewer adapter** for `window.MpJsApi` (`addMarker` and `addGeoJSONLayer`).

The WFS URL and feature type are intentionally configuration values because B-Plan publication in Brandenburg is distributed across different municipal services and not every plan exposes structured XPlan attributes.

### Example

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

console.log({
  grz: result.plan?.grz,
  gfz: result.plan?.gfz,
  grzMin: result.plan?.grzMin,
  grzMax: result.plan?.grzMax,
  gfzMin: result.plan?.gfzMin,
  gfzMax: result.plan?.gfzMax
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
