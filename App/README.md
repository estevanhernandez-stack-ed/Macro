# macRo — App target

Swift / SwiftUI app source. The Xcode project is generated from
[`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen);
`macRo.xcodeproj/` itself is gitignored.

## Generate / regenerate the Xcode project

```bash
cd App
xcodegen generate
```

Install XcodeGen first if needed: `brew install xcodegen`.

## Open the project

```bash
xed App/macRo.xcodeproj
```

…from the repo root, or open `App/macRo.xcodeproj` in Finder after
`xcodegen generate`.

## Layout (v1 shell only)

```
App/
├── project.yml              # XcodeGen source-of-truth
└── macRo/
    ├── App.swift            # @main entry
    ├── ContentView.swift    # placeholder window content
    ├── Info.plist           # bundle metadata + .macro UTI declaration
    ├── macRo.entitlements   # empty in v1; populated at item 11 (release pipeline)
    └── Theme/
        └── MacRoTheme.swift # 626Labs design-token stub
```

The full layered structure (`Native/`, `Domain/`, `UI/`, `Schema/`) lands as
later checklist items add wrappers, domain primitives, and views.
