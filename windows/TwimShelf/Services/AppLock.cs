// 应用锁: Windows Hello (face, fingerprint or PIN) at each start. It stands in front of the app; it
// does not encrypt the library's files.
using Microsoft.UI.Xaml;
using Windows.Security.Credentials.UI;
using WinRT.Interop;

namespace TwimShelf.Services;

public static class AppLock
{
    public static async Task<bool> Available()
    {
        try { return await UserConsentVerifier.CheckAvailabilityAsync() == UserConsentVerifierAvailability.Available; }
        catch { return false; }
    }

    /// True when the person is through, or Windows says Hello is no longer set up on this computer
    /// (not present, not configured, turned off by policy: the lock never keeps them out of their own
    /// library for good), as the Flutter app. Anything else that goes wrong (an error, a busy device)
    /// keeps the lock closed.
    public static async Task<bool> Unlock(Window owner)
    {
        UserConsentVerifierAvailability availability;
        try { availability = await UserConsentVerifier.CheckAvailabilityAsync(); }
        catch { return false; }
        if (availability is UserConsentVerifierAvailability.DeviceNotPresent or UserConsentVerifierAvailability.NotConfiguredForUser or UserConsentVerifierAvailability.DisabledByPolicy) return true;
        var hwnd = WindowNative.GetWindowHandle(owner);
        while (true)
        {
            UserConsentVerificationResult r;
            try { r = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(hwnd, Strings.L("applock.reason")); }
            catch (Exception e) { Diagnostics.Log("app lock: " + e.Message); return false; }
            if (r == UserConsentVerificationResult.Verified) return true;
            if (r is UserConsentVerificationResult.DeviceNotPresent or UserConsentVerificationResult.NotConfiguredForUser or UserConsentVerificationResult.DisabledByPolicy) return true;
            if (r == UserConsentVerificationResult.Canceled) return false;
            // RetriesExhausted, DeviceBusy: asked again (the dialog says why)
            if (r == UserConsentVerificationResult.DeviceBusy) await Task.Delay(800);
        }
    }
}
