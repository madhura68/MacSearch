# MacSearch

Native macOS app for one user. It searches a source folder for photos and videos whose file names contain the given keywords, shows the hits in a slider where you can untick files, and copies or moves the rest to `<destination>/<keyword>/<YYYY-MM-DD>/`. Searches and per-file actions are kept in SQLite.

## Build and test

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is generated and not tracked.

```bash
xcodegen generate
xcodebuild test -project MacSearch.xcodeproj -scheme MacSearch -destination 'platform=macOS'
```

## Documentation

- Spec: Scrum4Me ProductDoc `SPECS/idea-263-spec`
- Plan: `docs/plans/2026-10-16-idea-263-increment-1-plan.md`
- Review records: `docs/reviews/`
