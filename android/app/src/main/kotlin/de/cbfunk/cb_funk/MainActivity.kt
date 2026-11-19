package de.cbfunk.cb_funk

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val channelName = "de.cbfunk/ptt"
	private val actionPermission = "de.cbfunk.USB_PERMISSION"

	private var connection: UsbDeviceConnection? = null
	private var hidInterface: UsbInterface? = null
	private var pendingDevice: UsbDevice? = null
	private var pendingResult: MethodChannel.Result? = null
	private var receiverRegistered = false

	private val receiver = object : BroadcastReceiver() {
		override fun onReceive(context: Context, intent: Intent) {
			if (intent.action != actionPermission) return
			val dev = pendingDevice
			val res = pendingResult
			pendingDevice = null
			pendingResult = null
			if (dev == null || res == null) return
			val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
			res.success(if (granted) connect(dev) else false)
		}
	}

	private fun usb(): UsbManager = getSystemService(Context.USB_SERVICE) as UsbManager

	private fun hasHid(device: UsbDevice): Boolean {
		for (index in 0 until device.interfaceCount) {
			if (device.getInterface(index).interfaceClass == UsbConstants.USB_CLASS_HID) return true
		}
		return false
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		val filter = IntentFilter(actionPermission)
		if (Build.VERSION.SDK_INT >= 33) {
			registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
		} else {
			registerReceiver(receiver, filter)
		}
		receiverRegistered = true

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"listHid" -> result.success(listHid())
					"open" -> openDevice(
						call.argument<Int>("vid") ?: 0,
						call.argument<Int>("pid") ?: 0,
						result
					)
					"set" -> result.success(
						setGpio(call.argument<Int>("gpio") ?: 3, call.argument<Boolean>("on") ?: false)
					)
					"close" -> {
						closeConnection()
						result.success(true)
					}
					else -> result.notImplemented()
				}
			}

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.cbfunk/background_audio")
			.setMethodCallHandler { call, result ->
				val serviceIntent = Intent(this, BackgroundAudioService::class.java)
				when (call.method) {
					"start" -> {
						if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
							startForegroundService(serviceIntent)
						} else {
							startService(serviceIntent)
						}
						result.success(true)
					}
					"stop" -> result.success(stopService(serviceIntent))
					"status" -> {
						val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
						result.success(
							mapOf(
								"serviceRunning" to BackgroundAudioService.isRunning,
								"batteryOptimizationIgnored" to
									powerManager.isIgnoringBatteryOptimizations(packageName)
							)
						)
					}
					"openBatterySettings" -> {
						val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
						val exempt = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
							powerManager.isIgnoringBatteryOptimizations(packageName)
						val settingsIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !exempt) {
							Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
								data = Uri.parse("package:$packageName")
							}
						} else {
							Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
						}
						startActivity(settingsIntent)
						result.success(true)
					}
					else -> result.notImplemented()
				}
			}
	}

	private fun listHid(): List<Map<String, Any?>> {
		val devices = ArrayList<Map<String, Any?>>()
		for (device in usb().deviceList.values) {
			if (hasHid(device)) {
				devices.add(
					mapOf(
						"vid" to device.vendorId,
						"pid" to device.productId,
						"name" to (device.productName ?: "USB-HID")
					)
				)
			}
		}
		return devices
	}

	private fun pickDevice(vid: Int, pid: Int): UsbDevice? {
		val devices = usb().deviceList.values.filter { hasHid(it) }
		if (vid != 0) return devices.firstOrNull { it.vendorId == vid && it.productId == pid }
		return devices.firstOrNull {
			it.vendorId == 0x0D8C || (it.vendorId == 0x1209 && it.productId == 0x7388)
		} ?: devices.firstOrNull()
	}

	private fun openDevice(vid: Int, pid: Int, result: MethodChannel.Result) {
		val device = pickDevice(vid, pid)
		if (device == null) {
			result.error("nodev", "Kein USB-HID-Gerät gefunden", null)
			return
		}
		if (usb().hasPermission(device)) {
			result.success(connect(device))
			return
		}
		pendingDevice = device
		pendingResult = result
		val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
		val permissionIntent = PendingIntent.getBroadcast(
			this, 0, Intent(actionPermission).setPackage(packageName), flags
		)
		usb().requestPermission(device, permissionIntent)
	}

	private fun connect(device: UsbDevice): Boolean {
		closeConnection()
		val conn = usb().openDevice(device) ?: return false
		var found: UsbInterface? = null
		for (index in 0 until device.interfaceCount) {
			val usbInterface = device.getInterface(index)
			if (usbInterface.interfaceClass == UsbConstants.USB_CLASS_HID) {
				found = usbInterface
				break
			}
		}
		if (found == null) {
			conn.close()
			return false
		}
		conn.claimInterface(found, true)
		connection = conn
		hidInterface = found
		return true
	}

	private fun setGpio(gpio: Int, on: Boolean): Boolean {
		val conn = connection ?: return false
		val usbInterface = hidInterface ?: return false
		val mask = 1 shl (gpio - 1)
		val state = if (on) mask else 0
		val data = byteArrayOf(0, state.toByte(), mask.toByte(), 0)
		val transferred = conn.controlTransfer(0x21, 0x09, 0x0200, usbInterface.id, data, data.size, 1000)
		return transferred >= 0
	}

	private fun closeConnection() {
		try {
			val conn = connection
			val usbInterface = hidInterface
			if (conn != null && usbInterface != null) conn.releaseInterface(usbInterface)
			conn?.close()
		} catch (_: Exception) {
		}
		connection = null
		hidInterface = null
	}

	override fun onDestroy() {
		closeConnection()
		if (receiverRegistered) {
			try {
				unregisterReceiver(receiver)
			} catch (_: Exception) {
			}
			receiverRegistered = false
		}
		super.onDestroy()
	}
}
