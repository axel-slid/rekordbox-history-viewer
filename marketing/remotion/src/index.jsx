import {Composition, registerRoot} from "remotion";
import {SetPlayerDemo} from "./set-player-demo";

const RemotionRoot = () => (
  <Composition
    id="SetPlayerDemo"
    component={SetPlayerDemo}
    durationInFrames={480}
    fps={60}
    width={960}
    height={540}
  />
);

registerRoot(RemotionRoot);
