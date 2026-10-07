package org.sp8esa.esp32_datv

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Lists USB devices, asks for permission, opens a CDC-ACM device and claims its interfaces.
 * The Dart side does the transfers itself with usbdevfs ioctls on the returned file descriptor.
 */
class UsbSerialChannel(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "datv/usb")
    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val open = HashMap<String, UsbDeviceConnection>()
    private val action = context.packageName + ".USB_PERMISSION"

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(usb.deviceList.values.map { d ->
                mapOf(
                    "name" to d.deviceName,
                    "vid" to d.vendorId,
                    "pid" to d.productId,
                    "product" to (try { d.productName } catch (e: Exception) { null }),
                    "manufacturer" to (try { d.manufacturerName } catch (e: Exception) { null }),
                    "serial" to (try { if (usb.hasPermission(d)) d.serialNumber else null } catch (e: Exception) { null }),
                )
            })
            "open" -> {
                val name = call.argument<String>("name")!!
                val dev = usb.deviceList[name] ?: return result.error("nodev", "Device $name is gone", null)
                if (usb.hasPermission(dev)) openDevice(dev, result) else requestPermission(dev, result)
            }
            "close" -> {
                val name = call.argument<String>("name")!!
                open.remove(name)?.close()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(dev: UsbDevice, result: MethodChannel.Result) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                if (intent.action != action) return
                context.unregisterReceiver(this)
                if (usb.hasPermission(dev)) openDevice(dev, result)
                else result.error("denied", "USB permission denied", null)
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val intent = Intent(action).setPackage(context.packageName)
        usb.requestPermission(dev, PendingIntent.getBroadcast(context, 0, intent, flags))
    }

    private fun openDevice(dev: UsbDevice, result: MethodChannel.Result) {
        open.remove(dev.deviceName)?.close()
        val conn = usb.openDevice(dev) ?: return result.error("open", "Cannot open ${dev.deviceName}", null)
        var comm = -1
        var epIn = -1
        var epOut = -1
        var maxPacket = 64
        for (i in 0 until dev.interfaceCount) {
            val itf = dev.getInterface(i)
            if (itf.interfaceClass == UsbConstants.USB_CLASS_COMM && comm < 0) {
                comm = itf.id
                conn.claimInterface(itf, true)
            }
            if (itf.interfaceClass == UsbConstants.USB_CLASS_CDC_DATA && epIn < 0) {
                conn.claimInterface(itf, true)
                for (e in 0 until itf.endpointCount) {
                    val ep = itf.getEndpoint(e)
                    if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                    if (ep.direction == UsbConstants.USB_DIR_IN) epIn = ep.address
                    else { epOut = ep.address; maxPacket = ep.maxPacketSize }
                }
            }
        }
        if (epIn < 0 || epOut < 0) {
            conn.close()
            return result.error("nocdc", "No CDC data interface on ${dev.deviceName}", null)
        }
        open[dev.deviceName] = conn
        result.success(mapOf("fd" to conn.fileDescriptor, "epIn" to epIn, "epOut" to epOut,
            "iface" to (if (comm >= 0) comm else 0), "maxPacket" to maxPacket))
    }
}
