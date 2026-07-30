import {Composition, registerRoot} from "remotion";
import {SetPlayerDemo} from "./set-player-demo";

const RemotionRoot = () => (
  <Composition
    id="SetPlayerDemo"
    component={SetPlayerDemo}
    durationInFrames={240}
    fps={30}
    width={960}
    height={540}
  />
);

registerRoot(RemotionRoot);
