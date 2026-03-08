import AVFoundation
import CoreMedia

/// Provides manual control over the camera device parameters.
/// All methods must be called from any thread (they lock the device internally).
final class CameraConfigurator {
    private let device: AVCaptureDevice

    init(device: AVCaptureDevice) {
        self.device = device
    }

    // MARK: - Device Info

    var minISO: Float { device.activeFormat.minISO }
    var maxISO: Float { device.activeFormat.maxISO }
    var minExposureDuration: CMTime { device.activeFormat.minExposureDuration }
    var maxExposureDuration: CMTime { device.activeFormat.maxExposureDuration }
    var maxWhiteBalanceGain: Float { device.maxWhiteBalanceGain }

    // MARK: - ISO

    func setISO(_ iso: Float) {
        let clamped = max(minISO, min(iso, maxISO))
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: device.exposureDuration,
                                         iso: clamped)
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set ISO: \(error.localizedDescription)")
        }
    }

    // MARK: - Shutter Speed

    func setShutterSpeed(_ duration: CMTime) {
        let minDur = minExposureDuration
        let maxDur = maxExposureDuration

        let clampedSeconds = max(minDur.seconds, min(duration.seconds, maxDur.seconds))
        let clamped = CMTime(seconds: clampedSeconds, preferredTimescale: 1_000_000)

        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: clamped, iso: device.iso)
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set shutter speed: \(error.localizedDescription)")
        }
    }

    func setShutterSpeed(seconds: Double) {
        setShutterSpeed(CMTime(seconds: seconds, preferredTimescale: 1_000_000))
    }

    // MARK: - Exposure (ISO + Shutter Speed together)

    func setManualExposure(duration: CMTime, iso: Float) {
        let clampedISO = max(minISO, min(iso, maxISO))
        let minDur = minExposureDuration
        let maxDur = maxExposureDuration
        let clampedSeconds = max(minDur.seconds, min(duration.seconds, maxDur.seconds))
        let clampedDuration = CMTime(seconds: clampedSeconds, preferredTimescale: 1_000_000)

        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO)
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set exposure: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto Exposure

    func setAutoExposure() {
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set auto exposure: \(error.localizedDescription)")
        }
    }

    // MARK: - Focus

    func setFocus(_ lensPosition: Float) {
        let clamped = max(0.0, min(lensPosition, 1.0))
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: clamped)
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set focus: \(error.localizedDescription)")
        }
    }

    func setAutoFocus() {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set auto focus: \(error.localizedDescription)")
        }
    }

    // MARK: - White Balance

    func setWhiteBalance(temperature: Float, tint: Float) {
        let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: temperature, tint: tint
        )
        let gains = device.deviceWhiteBalanceGains(for: tempAndTint)
        let clampedGains = clampGains(gains)

        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: clampedGains)
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set white balance: \(error.localizedDescription)")
        }
    }

    func setAutoWhiteBalance() {
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to set auto WB: \(error.localizedDescription)")
        }
    }

    private func clampGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: max(1.0, min(gains.redGain, maxGain)),
            greenGain: max(1.0, min(gains.greenGain, maxGain)),
            blueGain: max(1.0, min(gains.blueGain, maxGain))
        )
    }

    // MARK: - HDR Under-Exposure

    /// Under-expose by the given number of stops to preserve highlights.
    /// Call this before burst capture for HDR mode.
    func applyHDRUnderexposure(stops: Float) {
        do {
            try device.lockForConfiguration()
            let currentDuration = device.exposureDuration
            let multiplier = pow(2.0, Double(-stops))
            let shorterDuration = CMTime(
                seconds: currentDuration.seconds * multiplier,
                preferredTimescale: 1_000_000
            )
            let clamped = max(minExposureDuration.seconds,
                              min(shorterDuration.seconds, maxExposureDuration.seconds))
            device.setExposureModeCustom(
                duration: CMTime(seconds: clamped, preferredTimescale: 1_000_000),
                iso: device.iso
            )
            device.unlockForConfiguration()
        } catch {
            Log.camera.error("Failed to apply HDR underexposure: \(error.localizedDescription)")
        }
    }
}
