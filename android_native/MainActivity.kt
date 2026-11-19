package __PKG__

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
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * USB-HID-PTT fuer CM108-kompatible Geraete (Soundkarten mit CM108/CM119, AIOC).
 * Schreibt den HID-Output-Report [0, Zustand, Maske, 0] per SET_REPORT.
 */
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

    private fun hasHid(d: UsbDevice): Boolean {
        for (i in 0 until d.interfaceCount) {
            if (d.getInterface(i).interfaceClass == UsbConstants.USB_CLASS_HID) return true
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
    }

    private fun listHid(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (d in usb().deviceList.values) {
            if (hasHid(d)) {
                out.add(
                    mapOf(
                        "vid" to d.vendorId,
                        "pid" to d.productId,
                        "name" to (d.productName ?: "USB-HID")
                    )
                )
            }
        }
        return out
    }

    private fun pickDevice(vid: Int, pid: Int): UsbDevice? {
        val list = usb().deviceList.values.filter { hasHid(it) }
        if (vid != 0) return list.firstOrNull { it.vendorId == vid && it.productId == pid }
        return list.firstOrNull {
            it.vendorId == 0x0D8C || (it.vendorId == 0x1209 && it.productId == 0x7388)
        } ?: list.firstOrNull()
    }

    private fun openDevice(vid: Int, pid: Int, result: MethodChannel.Result) {
        val dev = pickDevice(vid, pid)
        if (dev == null) {
            result.error("nodev", "Kein USB-HID-Gerät gefunden", null)
            return
        }
        if (usb().hasPermission(dev)) {
            result.success(connect(dev))
            return
        }
        pendingDevice = dev
        pendingResult = result
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(
            this, 0, Intent(actionPermission).setPackage(packageName), flags
        )
        usb().requestPermission(dev, pi)
    }

    private fun connect(dev: UsbDevice): Boolean {
        closeConnection()
        val conn = usb().openDevice(dev) ?: return false
        var found: UsbInterface? = null
        for (i in 0 until dev.interfaceCount) {
            val itf = dev.getInterface(i)
            if (itf.interfaceClass == UsbConstants.USB_CLASS_HID) {
                found = itf
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
        val itf = hidInterface ?: return false
        val mask = 1 shl (gpio - 1)
        val state = if (on) mask else 0
        val data = byteArrayOf(0, state.toByte(), mask.toByte(), 0)
        // bmRequestType 0x21 = Host->Geraet, Class, Interface; bRequest 0x09 = SET_REPORT
        // wValue = Output-Report (0x02) / Report-ID 0
        val r = conn.controlTransfer(0x21, 0x09, 0x0200, itf.id, data, data.size, 1000)
        return r >= 0
    }

    private fun closeConnection() {
        try {
            val conn = connection
            val itf = hidInterface
            if (conn != null && itf != null) conn.releaseInterface(itf)
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
