import { CaptureUpdateAction } from "@excalidraw/element";

import { laserPointerToolIcon } from "../components/icons";

import { register } from "./register";

export const actionToggleLaserPointerPersistence = register({
  name: "laserPointerPersistent",
  label: "labels.toggleLaserPersistence",
  icon: laserPointerToolIcon,
  viewMode: true,
  trackEvent: {
    category: "canvas",
    predicate: (appState) => !appState.laserPointerPersistent,
  },
  perform(elements, appState) {
    return {
      appState: {
        ...appState,
        laserPointerPersistent: !this.checked!(appState),
      },
      captureUpdate: CaptureUpdateAction.EVENTUALLY,
    };
  },
  checked: (appState) => appState.laserPointerPersistent,
});
