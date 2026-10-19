# FileGDB raster fixture

`gdal_test_data.gdb.zip` is format test data from GDAL's public test-data collection.

- Source: https://raw.githubusercontent.com/OSGeo/gdal/ddb8d0f7e1837a4a577801ab00509c253acb4a0f/autotest/gdrivers/data/filegdb/gdal_test_data.gdb.zip
- Upstream commit: `ddb8d0f7e1837a4a577801ab00509c253acb4a0f`
- Archive SHA-256: `0dc49bc299ffbe9503937b9469d8f8bda1519be1826410ff6c50a47e524a10ee`
- Size: 786,254 bytes.
- Redistribution: [GDAL test-data availability statement](https://github.com/OSGeo/gdal/blob/ddb8d0f7e1837a4a577801ab00509c253acb4a0f/autotest/README.md) describes this collection as public and freely redistributable geodata.

The archive is embedded only in the backend test executable and extracted to a private temporary directory. It is not an application runtime resource.

The `float32_lz77` and `float64_lz77` raster subdatasets each contain a 20 × 20 grid in NAD27 / UTM zone 11N (EPSG:26711). Pixel centers `(440750, 3751290)`, `(440810, 3751290)` and `(440870, 3751290)` have raw values 107, 123 and 132 respectively. The source transform is `(440720, 60, 0, 3751320, 0, -60)`. Tests use these known values, source bounds, typed NoData values and the unchanged complete directory manifest to validate the map reader.
