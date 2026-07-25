local _, ns = ...

-- Default bags and the bank both drive their item buttons through the global
-- SetItemButtonQuality, once per button per refresh, including empty slots:
--
--   ContainerFrameMixin:UpdateItems   -> SetItemButtonQuality(itemButton, ...)
--   BankPanelItemButtonMixin:Refresh  -> SetItemButtonQuality(self, ...)
--
-- Hooking it therefore covers the backpack, the separate and combined bag
-- views, the character bank and the warband bank without enumerating frames or
-- listening for bag events. Any bag addon that reuses Blizzard's item buttons
-- is picked up by the same hook.
--
-- ns.UpdateButton ignores buttons that are not bound to a container slot, which
-- is what keeps merchant, loot, mail and paperdoll buttons out of scope.
hooksecurefunc("SetItemButtonQuality", function(button)
  if button then
    ns.UpdateButton(button)
  end
end)
