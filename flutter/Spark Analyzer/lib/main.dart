import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

// TODO: Replace 500ms polling with BLE notifications (setNotifyValue + onValueReceived)
//       to reduce radio/battery usage and latency.
// TODO: Reconcile isOutputOn (user intent) with outputEN (device-reported state) —
//       currently the Switch can show a stale position if the device rejects a request.
// TODO: Fix widget_test.dart — imports wrong package name and tests a counter app that doesn't exist.

const String kDeviceName = "Spark Analyzer";
const String kServiceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String kCharacteristicUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ScanPage(),
    );
  }
}

class ScanPage extends StatefulWidget {
  @override
  _ScanPageState createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  List<BluetoothDevice> devices = [];
  bool isScanning = false;
  StreamSubscription? _scanSubscription;

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Spark Analyzer'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                textStyle: TextStyle(fontSize: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text('Start Scanning'),
              onPressed: () async {
                setState(() {
                  isScanning = true;
                });
                devices = [];
                _scanSubscription?.cancel();
                _scanSubscription = FlutterBluePlus.scanResults.listen((List<ScanResult> results) {
                  for (ScanResult result in results) {
                    var device = result.device;
                    if (!devices.contains(device)) {
                      setState(() {
                        devices.add(device);
                      });
                    }
                  }
                });
                await FlutterBluePlus.startScan(timeout: Duration(seconds: 4));
                await FlutterBluePlus.stopScan();
                setState(() {
                  isScanning = false;
                });
              },
            ),
          ),
          if (isScanning)
            CircularProgressIndicator(),
          Expanded(
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (context, index) {
                bool isSparkAnalyzer = devices[index].platformName == kDeviceName;

                return ListTile(
                  title: Text(devices[index].platformName.isEmpty ? "(unknown device)" : devices[index].platformName),
                  trailing: isSparkAnalyzer
                    ? ElevatedButton(
                        child: Text('Connect'),
                        onPressed: () async {
                          await devices[index].connect();
                          if (!mounted) return;
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ControlPage(device: devices[index]),
                            ),
                          );
                        },
                      )
                    : null,
                  tileColor: isSparkAnalyzer ? Colors.white : Colors.grey[300],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ControlPage extends StatefulWidget {
  final BluetoothDevice device;

  ControlPage({required this.device});

  @override
  _ControlPageState createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  bool isOutputOn = false;
  String selectedVoltage = "5";
  BluetoothCharacteristic? targetCharacteristic;
  StreamSubscription? deviceConnection;
  String? chosenDirectoryPath;
  Timer? _pollingTimer;
  bool _isLogging = false;
  bool _isSendingData = false;
  bool _isReading = false;

  String voltage = "";
  String current = "";
  String currentLimit = "0";
  String currentLimitReceived = "0";
  bool outputEN = false;

  @override
  void initState() {
    super.initState();
    discoverServices();

    deviceConnection = widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        Navigator.of(context).pop();
        widget.device.disconnect();
      }
    });

    _pollingTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (targetCharacteristic != null) {
        readBluetoothData();
      }
    });
  }

  @override
  void dispose() {
    deviceConnection?.cancel();
    _pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> discoverServices() async {
    try {
      List<BluetoothService> services = await widget.device.discoverServices();
      for (var service in services) {
        if (service.uuid.toString() == kServiceUuid) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString() == kCharacteristicUuid) {
              targetCharacteristic = characteristic;
            }
          }
        }
      }
    } catch (e) {
      print('Error discovering services: $e');
    }
  }

  void logDataToFile(Map<String, dynamic> parsedData) async {
    if (!_isLogging) return;

    try {
      String directoryPath = chosenDirectoryPath ?? (await getApplicationDocumentsDirectory()).path;
      final file = File('$directoryPath/spark_analyzer_log.csv');

      if (!await file.exists()) {
        await file.writeAsString("Timestamp,Voltage,Current,OutputEN,CurrentLimit\n");
      }

      String csvData = [
        DateTime.now().toIso8601String(),
        parsedData['Voltage'].toString(),
        parsedData['Current'].toString(),
        parsedData['OutputEN'] == true ? "Enabled" : "Disabled",
        parsedData['currentLimit'].toString(),
      ].join(",") + "\n";

      await file.writeAsString(csvData, mode: FileMode.append);
    } catch (e) {
      print('Error logging data: $e');
    }
  }

  Future<void> sendBluetoothData() async {
    if (targetCharacteristic == null || _isSendingData) return;

    _isSendingData = true;

    try {
      Map<String, dynamic> dataToSend = {
        'output': isOutputOn,
        'voltage': selectedVoltage,
        'currentLimit': currentLimit
      };
      String jsonData = jsonEncode(dataToSend);
      final List<int> data = utf8.encode(jsonData);

      await targetCharacteristic!.write(data, withoutResponse: false);
    } catch (e) {
      print('Error sending data: $e');
    } finally {
      _isSendingData = false;
    }
  }

  Future<void> readBluetoothData() async {
    if (targetCharacteristic == null || _isReading) return;

    _isReading = true;
    try {
      List<int> value = await targetCharacteristic!.read();

      if (value.isEmpty) return;

      String decodedValue = utf8.decode(value);
      Map<String, dynamic> parsedData = jsonDecode(decodedValue);

      bool isValidData = parsedData.containsKey('Voltage') &&
                          parsedData.containsKey('Current') &&
                          parsedData.containsKey('OutputEN') &&
                          parsedData.containsKey('currentLimit');
      if (!isValidData) {
        print('Incomplete data packet received, ignoring.');
        return;
      }

      if (!mounted) return;
      setState(() {
        voltage = (parsedData['Voltage'] ?? '').toString();
        current = (parsedData['Current'] ?? '').toString();
        outputEN = parsedData['OutputEN'] ?? false;
        currentLimitReceived = (parsedData['currentLimit'] ?? '0').toString();
      });

      logDataToFile(parsedData);
    } catch (e) {
      print('Error reading data: $e');
    } finally {
      _isReading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Control Panel'),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 600),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    elevation: 5,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text("Control", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Select Voltage:"),
                                    DropdownButton<String>(
                                      value: selectedVoltage,
                                      items: ['5', '9', '12', '15', '20'].map((String value) {
                                        return DropdownMenuItem<String>(
                                          value: value,
                                          child: Text(value),
                                        );
                                      }).toList(),
                                      onChanged: (newValue) {
                                        setState(() {
                                          selectedVoltage = newValue!;
                                        });
                                      },
                                    ),
                                    SizedBox(height: 16),
                                    Text("Toggle Output:"),
                                    Switch(
                                      value: isOutputOn,
                                      onChanged: (value) {
                                        setState(() {
                                          isOutputOn = value;
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('Send to Spark Analyzer'),
                                    SizedBox(height: 8),
                                    Container(
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).primaryColor,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: IconButton(
                                        iconSize: 24,
                                        icon: Icon(Icons.send, color: Colors.white),
                                        onPressed: () {
                                          sendBluetoothData();
                                        },
                                        tooltip: 'Send to Spark Analyzer',
                                      ),
                                    ),
                                    SizedBox(height: 16),
                                    Text("Current Limit (mA):"),
                                    Container(
                                      width: 100,
                                      child: TextField(
                                        keyboardType: TextInputType.number,
                                        onChanged: (String value) {
                                          setState(() {
                                            currentLimit = value;
                                          });
                                        },
                                        decoration: InputDecoration(
                                          hintText: "e.g., 1000",
                                          border: OutlineInputBorder(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 5),
                  Card(
                    elevation: 5,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text("Data from Spark Analyzer", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          SizedBox(height: 16),
                          Table(
                            columnWidths: const {
                              0: FlexColumnWidth(),
                              1: FlexColumnWidth(),
                            },
                            border: TableBorder.all(),
                            children: [
                              _tableRow("Voltage", voltage),
                              _tableRow("Current", current),
                              _tableRow("Output EN", outputEN ? "Enabled" : "Disabled"),
                              _tableRow("Current Limit Set", currentLimitReceived),
                            ],
                          ),
                          SizedBox(height: 20),
                          ElevatedButton(
                              child: Text('Choose Save Directory'),
                              onPressed: () async {
                                String? directoryPath = await FilePicker.platform.getDirectoryPath();
                                if (directoryPath != null) {
                                    setState(() {
                                        chosenDirectoryPath = directoryPath;
                                    });
                                }
                              },
                          ),
                          Text("Current Save Directory: ${chosenDirectoryPath ?? "Default App Directory"}"),
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                _isLogging = !_isLogging;
                              });
                            },
                            child: Text(_isLogging ? "Stop Logging" : "Start Logging"),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  TableRow _tableRow(String label, String value) {
    return TableRow(children: [
      Padding(padding: const EdgeInsets.all(8.0), child: Text(label)),
      Padding(padding: const EdgeInsets.all(8.0), child: Text(value)),
    ]);
  }
}
