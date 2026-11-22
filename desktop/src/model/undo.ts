// Bulk and destructive actions happen at once and offer Undo, instead of asking first
// (gui/Sources/Reader/Undo.swift). Each leaves a way back on this stack; Ctrl+Z and the
// toast's button take it.
import { createSignal } from "solid-js";
import { UndoStack } from "../logic/UndoStack";

export interface UndoItem {
  id: number;
  message: string;
  undo: () => Promise<void> | void;
}

export const TOAST_SECONDS = 6;

export function createUndoCenter() {
  const stack = new UndoStack<UndoItem>();
  const [toast, setToast] = createSignal<UndoItem | null>(null);
  const [count, setCount] = createSignal(0);
  let hide: ReturnType<typeof setTimeout> | undefined;
  let next = 1;

  function dismiss() {
    clearTimeout(hide);
    setToast(null);
  }

  function show(item: UndoItem) {
    setToast(item);
    clearTimeout(hide);
    hide = setTimeout(() => {
      if (toast()?.id === item.id) setToast(null);
    }, TOAST_SECONDS * 1000);
  }

  return {
    toast,
    canUndo: () => count() > 0,
    push(message: string, undo: UndoItem["undo"]) {
      const item = { id: next++, message, undo };
      stack.push(item);
      setCount(stack.count);
      show(item);
    },
    undoLast() {
      const item = stack.pop();
      setCount(stack.count);
      if (!item) return;
      if (toast()?.id === item.id) dismiss();
      void item.undo();
    },
    dismiss,
  };
}

export type UndoCenter = ReturnType<typeof createUndoCenter>;
