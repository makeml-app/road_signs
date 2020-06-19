//
//  ViewController.swift
//  Road Signs
//
//  Created by artyom korotkov on 3/25/20.
//  Copyright © 2020 artyom korotkov. All rights reserved.
//

import UIKit
import SnapKit
import CoreML
import Vision
import AVFoundation
import VideoToolbox
import CoreLocation
import SwiftOCR

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    let swiftOCRInstance = SwiftOCR()
    var lastRecognizedSpeedLimitTimeOfRecognition = Date()
    var roadSignsRecognizedDuringLastHalfOfSecond = [(String, Date)]()
    var currentSpeed: Int = 0
    var currentSpeedLimit: Int = 60
    private var detectionOverlay: CALayer! = nil
    private var requests = [VNRequest]()
    var image: UIImage?
    var photoOutput = AVCapturePhotoOutput()
    var bufferSize: CGSize = .zero
    var rootLayer: CALayer! = nil
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer! = nil
    private let videoDataOutput = AVCaptureVideoDataOutput()
    var objectBounds = [CGRect]()
    var currentImageFromPixelBuffer = UIImage()
    let locationManager = CLLocationManager()
    private let videoDataOutputQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    let containerView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.image = UIImage(named: "container")
        return imageView
    }()
    
    let speedLimitImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = UIImage(named: "60")
        return imageView
    }()
    
    let currentRoadSignImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()
    
    let currentSpeedLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.italicSystemFont(ofSize: 35)
        label.textColor = .white
        label.text = "60"
        label.textAlignment = .center
        return label
    }()
    
    let kilometersPerHourLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.italicSystemFont(ofSize: 20)
        label.textColor = .white
        label.text = "km/h"
        label.textAlignment = .center
        return label
    }()
    
    lazy var currentSpeedVerticalStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.alignment = .center
        stackView.axis = .vertical
        stackView.distribution = .fill
        stackView.addArrangedSubview(self.currentSpeedLabel)
        stackView.addArrangedSubview(self.kilometersPerHourLabel)
        return stackView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupAVCapture()
        setupSubviews()
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        if let image = UIImage(pixelBuffer: pixelBuffer) {
            currentImageFromPixelBuffer = image
        }
        
        let exifOrientation = exifOrientationFromDeviceOrientation()
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: exifOrientation, options: [:])
        do {
            try imageRequestHandler.perform(self.requests)
        } catch {
            print(error)
        }
    }
    
    var videoDevice : AVCaptureDevice? = nil
    
    func setupAVCapture() {
        var deviceInput: AVCaptureDeviceInput!
        
        // Select a video device, make an input
        if let videoDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTelephotoCamera], mediaType: .video, position: .back).devices.first {
            do {
                deviceInput = try AVCaptureDeviceInput(device: videoDevice)
            } catch {
                print("Could not create video device input: \(error)")
                return
            }
            
            self.videoDevice = videoDevice
            
            session.beginConfiguration()
            session.sessionPreset = .vga640x480 // Model image size is smaller.
            
            // Add a video input
            guard session.canAddInput(deviceInput) else {
                print("Could not add video device input to the session")
                session.commitConfiguration()
                return
            }
            session.addInput(deviceInput)
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
                session.addOutput(photoOutput)
                // Add a video data output
                videoDataOutput.alwaysDiscardsLateVideoFrames = true
                videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
                videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            } else {
                print("Could not add video data output to the session")
                session.commitConfiguration()
                return
            }
            let captureConnection = videoDataOutput.connection(with: .video)
            // Always process the frames
            captureConnection?.isEnabled = true
            do {
                try  videoDevice.lockForConfiguration()
                let dimensions = CMVideoFormatDescriptionGetDimensions((videoDevice.activeFormat.formatDescription))
                bufferSize.width = CGFloat(dimensions.width)
                bufferSize.height = CGFloat(dimensions.height)
                videoDevice.unlockForConfiguration()
            } catch {
                print(error)
            }
            session.commitConfiguration()
            session.sessionPreset = .inputPriority
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
            rootLayer = view.layer
            previewLayer.frame = rootLayer.bounds
            rootLayer.addSublayer(previewLayer)
            
            
            setupLayers()
            updateLayerGeometry()
            setupVision()
            
            // start the capture
            startCaptureSession()
        } else {
            showAlert("Supported camera not available")
        }
    }

    func showAlert(_ msg: String) {
        let avc = UIAlertController(title: "Error", message: msg, preferredStyle: .alert)
        avc.addAction(UIAlertAction(title: "Continue", style: .cancel, handler: nil))
        self.show(avc, sender: nil)
    }

    func startCaptureSession() {
        session.startRunning()
    }
    
    public func exifOrientationFromDeviceOrientation() -> CGImagePropertyOrientation {
        let curDeviceOrientation = UIDevice.current.orientation
        let exifOrientation: CGImagePropertyOrientation
        
        switch curDeviceOrientation {
        case UIDeviceOrientation.portraitUpsideDown:  // Device oriented vertically, home button on the top
            exifOrientation = .left
        case UIDeviceOrientation.landscapeLeft:       // Device oriented horizontally, home button on the right
            exifOrientation = .upMirrored
        case UIDeviceOrientation.landscapeRight:      // Device oriented horizontally, home button on the left
            exifOrientation = .down
        case UIDeviceOrientation.portrait:            // Device oriented vertically, home button on the bottom
            exifOrientation = .up
        default:
            exifOrientation = .up
        }
        return exifOrientation
    }
    
    func setupSubviews() {
        view.backgroundColor = .white
        view.addSubview(containerView)
        containerView.addSubview(currentRoadSignImageView)
        containerView.addSubview(speedLimitImageView)
        containerView.addSubview(currentSpeedVerticalStackView)
        
        containerView.snp.makeConstraints { (make) in
            make.bottom.equalTo(view).inset(20)
            make.left.right.equalTo(view).inset(10)
        }
        
        speedLimitImageView.snp.makeConstraints { (make) in
            make.right.equalToSuperview().inset(20)
            make.width.equalTo(containerView.snp.width).dividedBy(3).inset(10)
            make.centerY.equalToSuperview()
            make.height.equalTo(60)
        }
        
        currentRoadSignImageView.snp.makeConstraints { (make) in
            make.right.equalTo(speedLimitImageView.snp.left)
            make.width.centerY.height.equalTo(speedLimitImageView)
        }
        
        currentSpeedVerticalStackView.snp.makeConstraints { (make) in
            make.right.equalTo(currentRoadSignImageView.snp.left)
            make.width.centerY.height.equalTo(currentRoadSignImageView)
        }
        
    }
    
    func checkCurrentSpeedAndSpeedLimit() {
        if currentSpeed > currentSpeedLimit {
            self.currentSpeedLabel.textColor = UIColor.red
            self.kilometersPerHourLabel.textColor = UIColor.red
        } else {
            self.currentSpeedLabel.textColor = .white
            self.kilometersPerHourLabel.textColor = .white
        }
    }
    
    func createTextSubLayerInBounds(_ bounds: CGRect, identifier: String) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.name = "Object Label"
        let formattedString = NSMutableAttributedString(string: String(format: "\(identifier)"))
        let largeFont = UIFont(name: "Helvetica", size: 24.0)!
        formattedString.addAttributes([NSAttributedString.Key.font: largeFont], range: NSRange(location: 0, length: identifier.count))
        textLayer.string = formattedString
        textLayer.bounds = CGRect(x: 0, y: 0, width: bounds.size.width - 10, height: bounds.size.height - 10)
        textLayer.position = CGPoint(x: bounds.midX + 10, y: bounds.midY)
        textLayer.shadowOpacity = 0.7
        textLayer.shadowOffset = CGSize(width: 2, height: 2)
        textLayer.foregroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1.0, 1.0, 1.0, 1.0])
        textLayer.contentsScale = 2.0
        textLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(.pi / 2.0)).scaledBy(x: 1.0, y: -1.0))
        return textLayer
    }
    
    func cutoutDetectedMarkFromImage(image: UIImage, bounds: CGRect) -> UIImage {
        var newBounds = CGRect()
        newBounds.size.width = bounds.size.width
        newBounds.size.height = bounds.size.height
        newBounds.origin.x = bounds.origin.x
        newBounds.origin.y = image.size.height - bounds.origin.y - bounds.size.height
        print(bounds)
        print(newBounds)
        
        let cgImage = self.fixOrientation(img: image).cgImage?.cropping(to: newBounds)
        guard let resultCGImage = cgImage else { return UIImage() }
        var resultImage = UIImage(cgImage: resultCGImage)
        resultImage = resultImage.rotate(radians: .pi / 2)!
        return resultImage
    }
    
    func fixOrientation(img: UIImage) -> UIImage {
        if (img.imageOrientation == .up) {
            return img
        }

        UIGraphicsBeginImageContextWithOptions(img.size, false, img.scale)
        let rect = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
        img.draw(in: rect)

        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        return normalizedImage
    }

}

extension ViewController {
    
    @discardableResult
    func setupVision() -> NSError? {
        // Setup Vision parts
        let error: NSError! = nil
        
        guard let modelURL = Bundle.main.url(forResource: "Model", withExtension: "mlmodelc") else {
            return NSError(domain: "VisionObjectRecognitionViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model file is missing"])
        }
        do {
            let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            let objectRecognition = VNCoreMLRequest(model: visionModel, completionHandler: { [weak self] (request, error) in
                guard let self = self else { return }
                DispatchQueue.main.async(execute: {
                    // perform all the UI updates on the main queue
                    if let results = request.results {
                        self.drawVisionRequestResults(results)
                    }
                })
            })
            self.requests = [objectRecognition]
        } catch let error as NSError {
            print("Model loading went wrong: \(error)")
        }
        
        return error
    }
    
   
    
    func drawVisionRequestResults(_ results: [Any]) {
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        detectionOverlay.sublayers = nil // remove all the old recognized objects
        for observation in results where observation is VNRecognizedObjectObservation {
            guard let objectObservation = observation as? VNRecognizedObjectObservation else {
                continue
            }
            let topLabelObservation = objectObservation.labels[0]
            if topLabelObservation.confidence >= 0.9 {
                
                if objectObservation.boundingBox.width > 0.05 && objectObservation.boundingBox.height > 0.05 {
                    let objectBounds = VNImageRectForNormalizedRect(objectObservation.boundingBox, Int(bufferSize.width), Int(bufferSize.height))
                    
                    if (!objectBounds.width.isNaN && objectBounds.width != 0 && topLabelObservation.identifier == "speedlimit") {
                        
                        swiftOCRInstance.recognize(self.cutoutDetectedMarkFromImage(image: currentImageFromPixelBuffer, bounds: objectBounds)) { [weak self] recognizedString in
                            guard let self = self else { return }
                            var recognizedStringWithZeros = recognizedString.replacingOccurrences(of: "O", with: "0", options: .literal, range: nil) // replace all letters O in recognized string with number 0
                            recognizedStringWithZeros = recognizedStringWithZeros.replacingOccurrences(of: "o", with: "0", options: .literal, range: nil) // replace all letters o in recognized string with number 0
                            if recognizedStringWithZeros.count > 1 && Array(recognizedStringWithZeros)[1] != "2" {
                                recognizedStringWithZeros = recognizedStringWithZeros.replace(1, "0") // replace second character with 0 if it's not set to "2"
                            }
                            if recognizedStringWithZeros.count <= 1 {
                                recognizedStringWithZeros.append("0") // add "0" if string length is less than 2
                            }
                            if Array(recognizedStringWithZeros).count > 2 {
                                recognizedStringWithZeros = recognizedStringWithZeros.replace(2, "0") // replace third character with 0
                            }
                            while recognizedStringWithZeros.count > 3 {
                                recognizedStringWithZeros.removeLast() // fit string length to maximum 3 symbols
                            }
                            if let imageFromAssets = UIImage(named: recognizedStringWithZeros) { // if there is speed limit with this number in the library
                                if (self.lastRecognizedSpeedLimitTimeOfRecognition.timeIntervalSinceNow * -1 >= 1 || Int(recognizedStringWithZeros)! >= self.currentSpeedLimit) { // check if there's single speed limit and if not, select larger speed limit of two
                                    self.lastRecognizedSpeedLimitTimeOfRecognition = Date() // set time of last recognition of speed limit
                                    self.currentSpeedLimit = Int(recognizedStringWithZeros)! // set current speed limit
                                    DispatchQueue.main.async {
                                        self.speedLimitImageView.image = imageFromAssets
                                        self.checkCurrentSpeedAndSpeedLimit()
                                    }
                                }
                            }
                        }
                    } else {
                        self.setCurrentRoadSign(signTitle: topLabelObservation.identifier)
                    }
                    
                    let shapeLayer = self.createRoundedRectLayerWithBounds(objectBounds)
                    let textLayer = self.createTextSubLayerInBounds(objectBounds,
                                                                        identifier: topLabelObservation.identifier)
                    shapeLayer.addSublayer(textLayer)
                    
                    detectionOverlay.addSublayer(shapeLayer)
                }
            }
        }
        CATransaction.commit()
    }
    
    func setCurrentRoadSign(signTitle: String) {
        var roadSignForLastHalfOfSecondWithRemovedOldSigns = [(String, Date)]() // array, which contains speed limits recognized during last 0.5 seconds
        for (sign, time) in self.roadSignsRecognizedDuringLastHalfOfSecond {
            if signTitle == sign && time.timeIntervalSinceNow * -1 < 0.5 { // check if there's one more recognition of this sign in last 0.5 second
                self.currentRoadSignImageView.image = UIImage(named: signTitle) // update current road
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(removeCurrentSignImageView), object: nil) // ignore previous remove road sign image view method
                perform(#selector(removeCurrentSignImageView), with: nil, afterDelay: 5) // remove current road sign image view in 0.5 seconds
            }
            if (time.timeIntervalSinceNow * -1 < 0.5) { // check if road sign was recognized during last 0.5 seconds
                roadSignForLastHalfOfSecondWithRemovedOldSigns.append((sign, time))
            }
        }
        roadSignForLastHalfOfSecondWithRemovedOldSigns.append((signTitle, Date())) // append last recognized road sign
        self.roadSignsRecognizedDuringLastHalfOfSecond = roadSignForLastHalfOfSecondWithRemovedOldSigns // update array of recognized road signs for last 0.5 seconds
    }
    
    @objc func removeCurrentSignImageView() {
        self.currentRoadSignImageView.image = UIImage()
    }
    
    func setupLayers() {
        detectionOverlay = CALayer() // container layer that has all the renderings of the observations
        detectionOverlay.name = "DetectionOverlay"
        detectionOverlay.bounds = CGRect(x: 0.0,
                                         y: 0.0,
                                         width: bufferSize.width,
                                         height: bufferSize.height)
        detectionOverlay.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
        rootLayer.addSublayer(detectionOverlay)
    }
    
    func updateLayerGeometry() {
        let bounds = rootLayer.bounds
        var scale: CGFloat
        
        let xScale: CGFloat = bounds.size.width / bufferSize.height
        let yScale: CGFloat = bounds.size.height / bufferSize.width
        
        scale = fmax(xScale, yScale)
        if scale.isInfinite {
            scale = 1.0
        }
        CATransaction.begin()
        CATransaction.setValue(kCFBooleanTrue, forKey: kCATransactionDisableActions)
        
        // rotate the layer into screen orientation and scale and mirror
        detectionOverlay.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(.pi / 2.0)).scaledBy(x: scale, y: -scale))
        // center the layer
        detectionOverlay.position = CGPoint (x: bounds.midX, y: bounds.midY)
        
        CATransaction.commit()
    }
    
    func createRoundedRectLayerWithBounds(_ bounds: CGRect) -> CALayer {
        let shapeLayer = CALayer()
        shapeLayer.bounds = bounds
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.name = "Found Object"
        shapeLayer.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1.0, 1.0, 0.2, 0.4])
        shapeLayer.cornerRadius = 7
        return shapeLayer
    }
    
}

extension UIImage {
    public convenience init?(pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage? = nil
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)

        guard let cgImageUnwrapped = cgImage else {
            return nil
        }

        self.init(cgImage: cgImageUnwrapped)
    }
    
    func rotate(radians: Float) -> UIImage? {
        var newSize = CGRect(origin: CGPoint.zero, size: self.size).applying(CGAffineTransform(rotationAngle: CGFloat(radians))).size
        // Trim off the extremely small float value to prevent core graphics from rounding it up
        newSize.width = floor(newSize.width)
        newSize.height = floor(newSize.height)

        UIGraphicsBeginImageContextWithOptions(newSize, false, self.scale)
        let context = UIGraphicsGetCurrentContext()!

        // Move origin to middle
        context.translateBy(x: newSize.width/2, y: newSize.height/2)
        // Rotate around middle
        context.rotate(by: CGFloat(radians))
        // Draw the image at its center
        self.draw(in: CGRect(x: -self.size.width/2, y: -self.size.height/2, width: self.size.width, height: self.size.height))

        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return newImage
    }
}

// MARK: - CLLocationManagerDelegate

extension ViewController: CLLocationManagerDelegate {
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        
        if location.speed <= 0.5 {
            self.currentSpeed = 0
            self.currentSpeedLabel.text = "0"
            self.checkCurrentSpeedAndSpeedLimit()
            return
        }
        
        self.currentSpeedLabel.text = "\(Int(location.speed * 3.6))"
        self.currentSpeed = Int(location.speed * 3.6)
        self.checkCurrentSpeedAndSpeedLimit()
    }
}

extension String {
    func replace(_ index: Int, _ newChar: Character) -> String {
        var chars = Array(self)
        chars[index] = newChar
        let modifiedString = String(chars)
        return modifiedString
    }
}
