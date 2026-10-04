-- Host retains retired callbacks until their asynchronous cleanup completes.
-- This queue does not install an update hook or mutate loader registrations.
return function()
    local self = {}
    local pending = {}
    function self.add(owner, poll)
        assert(owner ~= nil and type(poll) == "function")
        if pending[owner] then
            return false, "Cleanup owner already registered"
        end
        pending[owner] = poll
        return true
    end
    function self.contains(owner)
        return pending[owner] ~= nil
    end
    function self.frame(dt)
        local errors = {}
        for owner, poll in pairs(pending) do
            local ok, done, why = pcall(poll, dt)
            if ok and done == true then
                pending[owner] = nil
            elseif not ok then
                errors[#errors + 1] = { owner = owner, error = done }
            elseif done == nil then
                errors[#errors + 1] =
                    { owner = owner, error = why or "Cleanup completion was not explicit" }
            end
        end
        return errors
    end
    return self
end
