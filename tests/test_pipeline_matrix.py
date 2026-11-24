#!/usr/bin/env python3
"""
Unit tests for azure-pipelines.yml matrix integrity and canonical Geofabrik URLs.

Uses only the Python 3 standard library.
"""

import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIPELINE_YAML = os.path.join(REPO_ROOT, "azure-pipelines.yml")

TRIPLE_RE = re.compile(
    r"OSM_REGION:\s*'([^']+)'\s+PBF_URL:\s*'([^']*)'\s+COUNTRY_CODE:\s*'([^']+)'"
)
PAIR_RE = re.compile(r"OSM_REGION:\s*'([^']+)'\s+PBF_URL:\s*'([^']*)'")
ANY_GEOFABRIK_URL_RE = re.compile(r"https://download\.geofabrik\.de/[^\s'\"]+")

DERIVED_COMPOSITE_REGIONS = frozenset({
    "guernsey",
    "jersey",
    "american-samoa",
    "guam",
    "northern-mariana-islands",
    "trinidad-and-tobago",
    "barbados",
    "antigua-and-barbuda",
    "dominica",
    "grenada",
    "saint-kitts-and-nevis",
    "saint-lucia",
    "saint-vincent-and-the-grenadines",
    "aruba",
    "curacao",
    "sint-maarten",
    "saint-martin",
    "saint-barthelemy",
    "cayman-islands",
    "turks-and-caicos-islands",
    "british-virgin-islands",
    "anguilla",
    "montserrat",
})


class TestPipelineMatrix(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(PIPELINE_YAML, "r", encoding="utf-8") as fh:
            cls.pipeline = fh.read()
        cls.triples = TRIPLE_RE.findall(cls.pipeline)

    def test_touchstones_and_matrix_have_no_duplicate_regions(self):
        regions = [reg for reg, _, _ in self.triples]
        self.assertGreaterEqual(len(regions), 220)
        self.assertEqual(
            len(regions),
            len(set(regions)),
            "Duplicate OSM_REGION found across touchstone jobs / convert matrix",
        )

        # Touchstone DE and US must live in their dedicated jobs, not in convert.matrix
        convert_matrix_section = self.pipeline.split("  - job: convert", 1)[1].split(
            "\n    steps:", 1
        )[0]
        matrix_regions = set(re.findall(r"OSM_REGION:\s*'([^']+)'", convert_matrix_section))
        self.assertNotIn("germany", matrix_regions)
        self.assertNotIn("us", matrix_regions)
        self.assertEqual(regions.count("germany"), 1)
        self.assertEqual(regions.count("us"), 1)

    def test_all_pbf_urls_are_canonical_geofabrik_format(self):
        all_urls = set(ANY_GEOFABRIK_URL_RE.findall(self.pipeline))
        pairs = PAIR_RE.findall(self.pipeline)
        self.assertEqual(len(pairs), len(self.triples))
        self.assertEqual(
            all_urls - {url for _, url in pairs if url},
            set(),
            "Found Geofabrik URL outside standard (OSM_REGION, PBF_URL) entries",
        )
        for reg, url in pairs:
            if url == "":
                self.assertIn(
                    reg,
                    DERIVED_COMPOSITE_REGIONS,
                    f"Empty PBF_URL is only allowed for derived composite regions, got '{reg}'",
                )
                continue
            self.assertNotIn(
                reg,
                DERIVED_COMPOSITE_REGIONS,
                f"Derived composite region '{reg}' must have empty PBF_URL '', got '{url}'",
            )
            self.assertTrue(
                url.startswith("https://download.geofabrik.de/"),
                f"Invalid Geofabrik URL scheme/host for '{reg}': {url}",
            )
            expected_suffix = f"/{reg}/{reg}-latest.osm.pbf"
            self.assertTrue(
                url.endswith(expected_suffix),
                f"Non-canonical PBF_URL for '{reg}' ('{url}'); expected suffix '{expected_suffix}'",
            )

    def test_all_entries_have_valid_country_codes(self):
        cc_pattern = re.compile(r"^[A-Z]{2}(-[A-Z]{2})?$")
        for reg, _, cc in self.triples:
            self.assertRegex(
                cc,
                cc_pattern,
                f"Invalid COUNTRY_CODE '{cc}' for region '{reg}'",
            )

    def test_release_stage_collects_all_places_parquet_artifacts(self):
        release_section = self.pipeline.split("- stage: release", 1)[1]
        self.assertIn("itemPattern: 'places-parquet-*/**'", release_section)


if __name__ == "__main__":
    unittest.main()
