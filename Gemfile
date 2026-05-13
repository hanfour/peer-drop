source "https://rubygems.org"

gem "fastlane"

# Minimum versions for fastlane's transitive deps that bundler-audit
# flagged with CVEs at audit time (2026-05-13):
#   - addressable <2.9.0 has ReDoS via templates (GHSA-h27x-rffw-24p4)
#   - faraday <1.10.5 / <2.14.1 has SSRF via protocol-relative URLs
#     (GHSA-33mh-2634-fwr2). Pin to 1.x because fastlane still uses
#     the 1.x API.
#   - json <2.19.2 has a format-string injection (GHSA-3m6g-2423-7cp3)
#
# Re-pin or remove these once fastlane's own gemspec catches up.
gem "addressable", ">= 2.9.0"
gem "faraday", "~> 1.10.5"
gem "json", ">= 2.19.2"
