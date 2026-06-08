//
//  ItemRowView.swift
//  MyInventory
//
//  Intentionally empty. The list row is now `DesignSystem/ItemCard`, rendered
//  inside `ContextListView`'s `List(selection:)`. The old `ItemRowView` became
//  dead code and used a second, divergent status palette
//  (SupplyStatus.color/.systemImage) — removed to keep a single source of truth
//  (`SupplyStatus.style`). This file is kept only because the workspace doesn't
//  permit deleting it; it can be removed in Xcode.
//
