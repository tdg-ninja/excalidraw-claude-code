import React from "react";

import { KEYS } from "@excalidraw/common";

import { Excalidraw } from "../index";

import { API } from "./helpers/api";
import { Keyboard } from "./helpers/ui";
import { act, fireEvent, render, waitFor } from "./test-utils";

const { h } = window;

const openHelpDialog = () => {
  act(() => {
    API.setAppState({ openDialog: { name: "help" } });
  });
};

// the HelpDialog is rendered into a portal appended to `document.body`,
// so it lives outside the render container.
const querySearchInput = () =>
  document.querySelector<HTMLInputElement>(".HelpDialog .QuickSearch__input");

const queryVisibleShortcutLabels = () =>
  Array.from(
    document.querySelectorAll(".HelpDialog__shortcut > div:first-child"),
  ).map((el) => el.textContent);

describe("HelpDialog", () => {
  beforeEach(async () => {
    await render(<Excalidraw handleKeyboardGlobally />);
  });

  it("pressing CtrlOrCmd+F while open should not close the dialog or open canvas search", async () => {
    openHelpDialog();
    await waitFor(() => expect(querySearchInput()).not.toBeNull());

    Keyboard.withModifierKeys({ ctrl: true }, () => {
      Keyboard.keyPress(KEYS.F, document.activeElement as HTMLElement);
    });

    expect(h.state.openDialog?.name).toBe("help");
    expect(h.state.openSidebar).toBeNull();
  });

  it("pressing CtrlOrCmd+F while open should focus the in-dialog search input", async () => {
    openHelpDialog();
    await waitFor(() => expect(querySearchInput()).not.toBeNull());

    // simulate the keypress originating from whatever is currently focused
    // inside the dialog (e.g. due to the dialog's initial autofocus), so it
    // bubbles up through the dialog's DOM the same way a real keypress would
    Keyboard.withModifierKeys({ ctrl: true }, () => {
      Keyboard.keyPress(KEYS.F, document.activeElement as HTMLElement);
    });

    expect(document.activeElement).toBe(querySearchInput());
  });

  it("typing in the search input filters the visible shortcuts", async () => {
    openHelpDialog();
    const searchInput = querySearchInput()!;
    await waitFor(() => expect(searchInput).not.toBeNull());

    expect(queryVisibleShortcutLabels()).toContain("Rectangle");
    expect(queryVisibleShortcutLabels()).toContain("Hand (panning tool)");

    fireEvent.change(searchInput, { target: { value: "rectangle" } });

    await waitFor(() => {
      const labels = queryVisibleShortcutLabels();
      expect(labels).toContain("Rectangle");
      expect(labels).not.toContain("Hand (panning tool)");
    });
  });
});
