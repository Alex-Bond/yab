These three JSON resources are unchanged actual outputs fetched from the owned AWS job
9f7b0d5f4c604831, source snapshot 944f6c2722068ceca102523480119c48a2d67e3a.
The job executed field-presentation-oracle.py and generated all 288 Swift cases successfully.
Its later Android compile failed separately at BrowserScreen's nested maxHeight scope;
no native Field test ran in that job.

SHA256:
- current-ios-vectors.json: 9d4b3680c58bbdc704951dbe8c77a2009169a1c82b7086ccc28cfa6a741a7062
- current-ios-inputs.json: 13fdb5464fda80eaeafb31ff3194209bd95480f17db63885ab674f57301a724e
- current-ios-source-pins.json: 97197e12b6f2615f353d343e19126b30ea85558619f9670b54901819f4a01271

BrowserFieldSwiftParityTest pins those exact bytes, actual source snapshot and six source
hashes, validates the complete input corpus, then compares both native Swift rectangles and
all geometry scalars to the Kotlin consumer. There is no Android-generated golden.
The source inputs still matched the checkout when these resources were imported.

The font line height is an explicit scalar input. Neither this corpus nor its JVM consumer
proves UIKit/Android font measurement, OS keyboard callbacks, blur, native frame timing or
presented pixels. All receipt boundary flags remain false. The consumer tests were authored
but have not yet run; the next root-owned build is responsible for execution evidence.
