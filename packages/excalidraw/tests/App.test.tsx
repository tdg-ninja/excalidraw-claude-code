import React from "react";
import { vi } from "vitest";

import { reseed } from "@excalidraw/common";

import { Excalidraw } from "../index";
import * as StaticScene from "../renderer/staticScene";
import {
  render,
  queryByTestId,
  unmountComponent,
  fireEvent,
  act,
} from "../tests/test-utils";

const renderStaticScene = vi.spyOn(StaticScene, "renderStaticScene");

vi.mock("../data/filesystem.ts", async (importOriginal) => {
  const module = await importOriginal();
  return {
    __esmodule: true,
    //@ts-ignore
    ...module,
    fileSave: vi.fn(() => Promise.resolve(null)),
  };
});

describe("Test <App/>", () => {
  beforeEach(async () => {
    unmountComponent();
    localStorage.clear();
    renderStaticScene.mockClear();
    reseed(7);
  });

  it("should show error modal when using brave and measureText API is not working", async () => {
    (global.navigator as any).brave = {
      isBrave: {
        name: "isBrave",
      },
    };

    const originalContext = global.HTMLCanvasElement.prototype.getContext("2d");
    //@ts-ignore
    global.HTMLCanvasElement.prototype.getContext = (contextId) => {
      return {
        ...originalContext,
        measureText: () => ({
          width: 0,
        }),
      };
    };

    await render(<Excalidraw />);
    expect(
      queryByTestId(
        document.querySelector(".excalidraw-modal-container")!,
        "brave-measure-text-error",
      ),
    ).toMatchSnapshot();
  });

  it("should always preventDefault on Ctrl/Cmd+S, even while a text input is focused, so the browser's native save dialog never fires (#9281)", async () => {
    await render(<Excalidraw handleKeyboardGlobally={true} />);

    const input = document.createElement("input");
    input.type = "text";
    document.body.appendChild(input);
    input.focus();

    // `fireEvent.keyDown` returns `false` when a listener called
    // `preventDefault()`, meaning the browser won't run its default action.
    let wasNotPrevented = true;
    await act(async () => {
      wasNotPrevented = fireEvent.keyDown(input, {
        key: "s",
        ctrlKey: true,
      });
      await Promise.resolve();
    });

    expect(wasNotPrevented).toBe(false);

    document.body.removeChild(input);
  });
});
