import { vi } from "vitest";

import { Excalidraw } from "../index";
import * as InteractiveScene from "../renderer/interactiveScene";

import { API } from "./helpers/api";
import { act, render, waitFor } from "./test-utils";

import type { Collaborator, SocketId } from "../types";

describe("collaborator editing indicator", () => {
  const h = window.h;

  it("marks an element as being edited by a remote collaborator", async () => {
    const renderInteractiveScene = vi.spyOn(
      InteractiveScene,
      "renderInteractiveScene",
    );

    await render(<Excalidraw />);

    const text = API.createElement({ type: "text", x: 10, y: 10 });
    API.setElements([text]);

    const socketId = "socket-id" as SocketId;
    const collaborators = new Map<SocketId, Collaborator>([
      [
        socketId,
        {
          username: "Other User",
          editingElementId: text.id,
        },
      ],
    ]);

    act(() => {
      h.app.updateScene({ collaborators });
    });

    await waitFor(() => {
      const lastCall =
        renderInteractiveScene.mock.calls[
          renderInteractiveScene.mock.calls.length - 1
        ];
      expect(lastCall).toBeDefined();
      expect(
        lastCall![0].renderConfig.remoteEditingElementIds.get(text.id),
      ).toEqual([socketId]);
    });

    renderInteractiveScene.mockRestore();
  });

  it("does not mark an element as being edited when only remotely selected", async () => {
    const renderInteractiveScene = vi.spyOn(
      InteractiveScene,
      "renderInteractiveScene",
    );

    await render(<Excalidraw />);

    const text = API.createElement({ type: "text", x: 10, y: 10 });
    API.setElements([text]);

    const socketId = "socket-id" as SocketId;
    const collaborators = new Map<SocketId, Collaborator>([
      [
        socketId,
        {
          username: "Other User",
          selectedElementIds: { [text.id]: true },
        },
      ],
    ]);

    act(() => {
      h.app.updateScene({ collaborators });
    });

    await waitFor(() => {
      const lastCall =
        renderInteractiveScene.mock.calls[
          renderInteractiveScene.mock.calls.length - 1
        ];
      expect(lastCall).toBeDefined();
      expect(
        lastCall![0].renderConfig.remoteSelectedElementIds.get(text.id),
      ).toEqual([socketId]);
      expect(
        lastCall![0].renderConfig.remoteEditingElementIds.get(text.id),
      ).toBeUndefined();
    });

    renderInteractiveScene.mockRestore();
  });
});
