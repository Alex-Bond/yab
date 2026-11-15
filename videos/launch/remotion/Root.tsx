import React from "react";
import { Composition } from "remotion";
import { FILM1, FILM2, FILM3, Film1, Film2, Film3 } from "./films";
import { FPS } from "./parts";

export const Root: React.FC = () => (
  <>
    <Composition id="Film1" component={Film1} durationInFrames={FILM1} fps={FPS} width={1920} height={1080} />
    <Composition id="Film2" component={Film2} durationInFrames={FILM2} fps={FPS} width={1920} height={1080} />
    <Composition id="Film3" component={Film3} durationInFrames={FILM3} fps={FPS} width={1920} height={1080} />
  </>
);
