# Regenerate the API spec

```powershell
python spec/build_routes_full.py   # parse every registration at tag v1.5.0, probe live
python spec/probe_openapi.py       # probe the repo's OpenAPI, capture response samples
python spec/make_spec.py           # write spec/API.md and spec/OTDA.openapi.json
```

