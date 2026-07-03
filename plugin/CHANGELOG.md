# Changelog

## [1.0.1](https://github.com/gruesomeparty/severance/compare/plugin-v1.0.0...plugin-v1.0.1) (2026-07-03)


### Bug Fixes

* **commands:** let Claude invoke /severance:severance-status ([6172f52](https://github.com/gruesomeparty/severance/commit/6172f5266567a148b087cc9ac7fe8a9d161268e8))
* **scripts:** cost cap reads THIS session's cost, not a sibling's (D6) ([7e89129](https://github.com/gruesomeparty/severance/commit/7e8912987ebe520883a2fc88b1b9bc245af1d97e))
* **scripts:** resume submits the prompt (separate delayed Enter) ([f6d7c71](https://github.com/gruesomeparty/severance/commit/f6d7c71279af31183211019090ad03def56266a1))

## 1.0.0 (2026-07-03)


### Features

* **commands:** add /severance:severance-status ([6816e0a](https://github.com/suTerminus/severance/commit/6816e0a99e7be02645ac11dae3f1f16f520061aa))
* **plugin:** add plugin, hooks, and marketplace manifests ([4b7727b](https://github.com/suTerminus/severance/commit/4b7727bf05471c55eeceef72b0b71ec35c2c0d3e))
* **scripts:** add gate.sh budget gate (PreToolUse + SessionStart) ([c646efe](https://github.com/suTerminus/severance/commit/c646efe5088ab3295360562b316a4e76ad364a84))
* **scripts:** add heartbeat.sh Stop-hook state refresh ([c3c8575](https://github.com/suTerminus/severance/commit/c3c857541ee89dedf83116393b61ecf2d2a3075c))
* **scripts:** add ladder, project-state I/O, and preemption to severance-lib.sh ([dfc8897](https://github.com/suTerminus/severance/commit/dfc88979bd60c6f7fc966b3d2eda2368aa63ab77))
* **scripts:** add oauth-usage.sh Tier-2 fallback ([319a56f](https://github.com/suTerminus/severance/commit/319a56f8cbfc994bfa57a77766c5e32e464db927))
* **scripts:** add resume.sh and schedule-resume.sh ([b45f2a9](https://github.com/suTerminus/severance/commit/b45f2a97d4af4352987a1574a2ac0a7a70f7159f))
* **scripts:** add severance-lib.sh signal core ([22f9b87](https://github.com/suTerminus/severance/commit/22f9b878d33b0a45b49e673b206fe179857f5d05))
* **scripts:** add statusline-bridge.sh Tier-1 capture ([c4a339b](https://github.com/suTerminus/severance/commit/c4a339bf17abdfa68b47c2bc124d6ab80c3d10db))
* **skills:** add configuring-severance and severance-compat-check ([ad982cf](https://github.com/suTerminus/severance/commit/ad982cfda219b54c3b9a5c138f966bdfb8566a6f))
