# Release readiness records

`promote-prod.yml` refuses to shift prod traffic for tag `vX.Y.Z` unless
`releases/vX.Y.Z-readiness.md` exists on that tag and contains a line that is exactly:

```
VERDICT: GO
```

Write the record (what was checked, by whom, the verdict) and merge it before tagging the release.
