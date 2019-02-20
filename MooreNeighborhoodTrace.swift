
//
// MooreNeighborhoodTrace.swift
//
// Created by Russell Okamoto on 2/19/19.
// Copyright © 2019. All rights reserved.
//
// Get Moore Neighborhood Trace from an image.
//
// Returns a CGPath from a CIImage or CGImage or SKTexture or MTLTexture.
//
// MooreNeighborhoodTrace().shared.getMoorePath(ciImage:scaleDownBy:blurRadius)
// MooreNeighborhoodTrace().shared.getMoorePath(cgImage:scaleDownBy:blurRadius)
// MooreNeighborhoodTrace().shared.getMoorePath(skTexture:scaleDownBy:blurRadius)
// MooreNeighborhoodTrace().shared.getMoorePath(mtlTexture:)
//
// Use scaleDownBy to improve performance (default scales down image by 0.1)
// After downscaling, the returned CGPath should be scaled back up by the caller so that the path matches the
// size of the original image.
//
// Use blurRadius to fill gaps in image (default blurRadius is 2.0; applies Guassian filter to blur image)
//
// Assumes transparent border padding around the image to be traced (to avoid corner and edge conditions
// where a trace could begin on the edge of the image).
//
// Thanks to:
// http://www.imageprocessingplace.com/downloads_V3/root_downloads/tutorials/contour_tracing_Abeer_George_Ghuneim/moore.html

import Foundation
import UIKit
import CoreImage
import SpriteKit
import MetalKit

class MooreNeighborhoodTrace {
    
    enum Direction {
        case northWest
        case north
        case northEast
        case east
        case southEast
        case south
        case southWest
        case west
    }
    
    static let shared = MooreNeighborhoodTrace()
    
    private init(){}
    
    let alphaThreshold: UInt8 = 8
    let bytesPerPixel: Int = 4
    var beforeCurrentPixel: (x: Int, y: Int)?
    var startPixel: (x: Int, y: Int)?
    var currentPixel: (x: Int, y: Int)?
    var path: CGMutablePath?
    var texture: MTLTexture!
    
    // The total number of bytes of the texture
    var imageByteCount: Int!
    // The number of bytes for each image row
    var bytesPerRow: Int!
    // An empty buffer that will contain the image
    //var src: [UInt8]!
    // Gets the bytes from the texture
    var region: MTLRegion!
    var maxCol: Int!
    var maxRow: Int!
    
    private func isBorder(pixel: (x: Int, y: Int), src: [UInt8]) -> Bool {
        
        let row = pixel.y
        let col = pixel.x
        
        // If row or col coordinates are negative then the pixel is out of bounds of the texture
        if row < 0 || col < 0 || row > maxRow || col > maxCol {
            return false
        }
        
        // Translate the row and col to pixelId
        let pixelNum = (row * texture.width) + col
        let pixelId = pixelNum * bytesPerPixel
        let alphaId = pixelId + 3
        if alphaId > src.count {
            return false
        }
        
        let pixelByteR = src[pixelId]
        let pixelByteG = src[pixelId + 1]
        let pixelByteB = src[pixelId + 2]
        
        // Offset 3 (0 based) is the alpha channel
        let pixelByteA = src[pixelId + 3]
        
        if pixelByteA > alphaThreshold /* && (pixelByteR > threshold || pixelByteG > threshold || pixelByteB > threshold) */ {
            //print("YES BORDER (\(col), \(row)) RGBA = [\(src[pixelId]), \(src[pixelId+1]), \(src[pixelId+2]), \(pixelByteA)] < \(alphaThreshold)")
            return true
        } else {
            //print("NO BORDER (\(col), \(row)) RGBA = [\(src[pixelId]), \(src[pixelId+1]), \(src[pixelId+2]), \(pixelByteA)] < \(alphaThreshold)")
            return false
        }
        
    }
    
    private func addPixelToPath(pixel: (x: Int,y: Int)) {
        
        path?.addLine(to: CGPoint(x: pixel.x, y: pixel.y))

        /*
        if path == nil {
            path = CGMutablePath()
            path?.move(to: CGPoint(x: (startPixel?.0)!, y: (startPixel?.1)!))
        } else {
            path?.addLine(to: CGPoint(x: pixel.x, y: pixel.y))
        }*/

    }
    
    private func getPixelValues(pixel: (x: Int, y: Int), src: [UInt8]) -> (UInt8, UInt8, UInt8, UInt8) {
        
        let row = pixel.y
        let col = pixel.x
        
        // If row or col coordinates are negative then the pixel is out of bounds of the texture
        if row < 0 || col < 0 {
            return (0, 0, 0, 0)
        }
        
        // Translate the row and col to pixelId
        let pixelNum = (row * texture.width) + col
        let pixelId = pixelNum * bytesPerPixel
        
        let pixelByteR: UInt8 = src[pixelId]
        let pixelByteG: UInt8 = src[pixelId + 1]
        let pixelByteB: UInt8 = src[pixelId + 2]
        let pixelByteA: UInt8 = src[pixelId + 3]
        
        return (pixelByteR, pixelByteG, pixelByteB, pixelByteA)
        
    }
    
    private func getNeighboringPixel(pixel: (x: Int, y: Int), direction: Direction) -> (x: Int, y: Int)? {
        
        var row = pixel.y
        var col = pixel.x
        
        switch direction {
        case .north:
            row += -1
        case .northEast:
            row += -1
            col += 1
        case .east:
            col += 1
        case .southEast:
            row += 1
            col += 1
        case .south:
            row += 1
        case .southWest:
            row += 1
            col += -1
        case .west:
            col += -1
        case .northWest:
            row += -1
            col += -1
        }
        
        if row < 0 || col < 0 || row > maxRow || col > maxCol {
            return nil
        } else {
            //print("getPixel [\(col), \(row)] for \(direction) of [\(pixel.x), \(pixel.y)] with value \( getPixelValues(pixel: (col, row)))")
            return (col, row)
        }
        
    }
    
    // Get direction moving from previousPixel to currentPixel
    // Utilized when new border pixel is found to determine next direction of trace
    private func getHeading(from previousPixel: (x: Int, y: Int), to currentPixel: (x: Int, y: Int)) -> Direction? {
        
        let xDelta = previousPixel.x - currentPixel.x
        let yDelta = previousPixel.y - currentPixel.y
        
        //  +----------+----------+----------+
        //  |(x-1,y-1) | (x,y-1)  |(x+1,y-1) |
        //  |          |          |          |
        //  +----------+----------+----------+
        //  |(x-1,y)   |  (x,y)   |(x+1,y)   |
        //  |          |          |          |
        //  +----------+----------+----------+
        //  |(x-1,y+1) | (x,y+1)  |(x+1,y+1) |
        //  |          |          |          |
        //  +----------+----------+----------+
        
        if xDelta == 0 && yDelta == -1 {
            return .north
        } else if xDelta == 1 && yDelta == -1 {
                return .northEast
            } else if xDelta == 1 && yDelta == 0 {
                    return .east
                } else if xDelta == 1 && yDelta == 1 {
                        return .southEast
                    } else if xDelta == 0 && yDelta == 1 {
                            return .south
                        } else if xDelta == -1 && yDelta == 1 {
                                return .southWest
                            } else if xDelta == -1 && yDelta == 0 {
                                    return .west
                                } else if xDelta == -1 && yDelta == -1 {
                                        return .northWest
                                    } else {
                                        // shouldn't happen with clear padding on shape
                                        return nil
        }
        
    }
    
    private func getNextClockwiseDirection(from: Direction) -> Direction {
        
        switch from {
        case .north:
            return .northEast
        case .northEast:
            return .east
        case .east:
            return .southEast
        case .southEast:
            return .south
        case .south:
            return .southWest
        case .southWest:
            return .west
        case .west:
            return .northWest
        case .northWest:
            return .north
        }
        
    }
    
    
    // Invoke with SKTexture
    func getMoorePath(skTexture: SKTexture, scaleDownBy: CGFloat = 0.1, blurRadius: Double = 2.0) -> CGPath? {
        
        // convert SKTexture to CGImage to CIImage
        let ciImage = CIImage(cgImage: (skTexture.cgImage()))
        return getMoorePath(ciImage: ciImage, scaleDownBy: scaleDownBy, blurRadius: blurRadius)
        
    }
    
    // Invoke with CGImage
    func getMoorePath(cgImage: CGImage, scaleDownBy: CGFloat = 0.1, blurRadius: Double = 2.0) -> CGPath? {

        // convert CGImage to CIImage
        let ciImage = CIImage(cgImage: cgImage)
        return getMoorePath(ciImage: ciImage, scaleDownBy: scaleDownBy, blurRadius: blurRadius)
        
    }
    
    // Invoke with CIImage
    func getMoorePath(ciImage: CIImage, scaleDownBy: CGFloat = 0.1, blurRadius: Double = 2.0) -> CGPath? {
        
        // Scale way down first and invert Y axis!
        let scaledDownImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleDownBy, y: -scaleDownBy))
        
        // Blur image to fill gaps in image
        let blurredImage = scaledDownImage.applyingGaussianBlur(sigma: blurRadius)
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            return path
        }
        
        // Create a CGImage
        let context = CIContext(mtlDevice: device)
        let cgImage = context.createCGImage(blurredImage, from: blurredImage.extent, format: CIFormat.RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB(), deferred: false)

        let loader = MTKTextureLoader(device: device)
        do {
            // Create a MTLTexture from CGImage
            let mtlTexture = try loader.newTexture(cgImage: cgImage!, options: [: ])
            
            // Invoke base MTLTexture version
            return getMoorePath(mtlTexture: mtlTexture)
            
        } catch {
            
            return path
            
        }

    }
    
    // Invoke with MTLTexture
    func getMoorePath(mtlTexture tex: MTLTexture) -> CGPath? {
        
        // Store the texture in the property
        texture = tex
        
        // Total number of bytes of the texture
        imageByteCount = texture.width * texture.height * bytesPerPixel
        
        // Number of bytes for each image row
        bytesPerRow = texture.width * bytesPerPixel

        // Region for copying
        region = MTLRegionMake2D(0, 0, texture.width, texture.height)

        // An empty buffer that will contain the image
        // NOTE: self.src: [UInt8]! property does not work here! src is nil after getBytes()
        // so use a local src variable instead
        var src = [UInt8](repeating: 0, count: Int(imageByteCount))
        
        // Get the bytes from the texture
        texture.getBytes(&src, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        maxCol = (texture.width - 1)
        maxRow = (texture.height - 1)
        
        // 1. Find first border pixel
        //print("texture w \(texture.width) h \(texture.height) maxCol \(maxCol) x maxRow \(maxRow)")
        outerLoop: for row in 0...maxRow {
            for col in 0...maxCol {
                
                if isBorder(pixel: (col, row), src: src) {
                    
                    let pixelNum = (row * texture.width) + col
                    let pixelId = pixelNum * bytesPerPixel
                    let pixelByteR = src[pixelId]
                    let pixelByteG = src[pixelId + 1]
                    let pixelByteB = src[pixelId + 2]
                    let pixelByteA = src[pixelId + 3]
                    //print("Found start pixel \(pixelId): [\(col),\(row)] = (\(pixelByteR), \(pixelByteG), \(pixelByteB), \(pixelByteA))" )
                    startPixel = (col, row)
                    break outerLoop
                    
                } else {
                    
                    // Remember the pixel that comes just before startPixel
                    beforeCurrentPixel = (col, row)
                    
                    let pixelNum = (row * texture.width) + col
                    let pixelId = pixelNum * bytesPerPixel
                    let pixelByteR = src[pixelId]
                    let pixelByteG = src[pixelId + 1]
                    let pixelByteB = src[pixelId + 2]
                    let pixelByteA = src[pixelId + 3]
                    //print("\(pixelId): [\(col),\(row)] = (\(pixelByteR), \(pixelByteG), \(pixelByteB), \(pixelByteA))" )
                    
                }
                
            }
            
        }
        
        guard startPixel != nil else {
            return nil
        }
        
        // 2. Create new path and add startPixel
        path = CGMutablePath()
        path?.move(to: CGPoint(x: (startPixel?.0)!, y: (startPixel?.1)!))
        
        if beforeCurrentPixel == nil {
            beforeCurrentPixel = (x:0, y:0)
        }
        
        // 3. Get direction FROM beforeCurrentPixel TOWARD currentPixel
        let startDirection = getHeading(from: beforeCurrentPixel!, to: startPixel!)!
        
        // 4. Advance startDirection clockwise to nextDirection
        let nextDirection = getNextClockwiseDirection(from: startDirection)
        
        // 5. ITERATIVELY find next border pixels until encountering startPixel and beginPixel
        var currentDirection = nextDirection
        currentPixel = startPixel
        var encounteredStartPixelFromStartDirection = false
        
        while (!encounteredStartPixelFromStartDirection) {
            
            if let pixel = getNeighboringPixel(pixel: currentPixel!, direction: currentDirection) {
                
                // Check for Jacob's stopping condition
                if pixel.x == beforeCurrentPixel!.x && pixel.y == beforeCurrentPixel!.y && currentPixel!.x == startPixel!.x && currentPixel!.y == startPixel!.y  {
                    
                    // stop iterating
                    encounteredStartPixelFromStartDirection = true
                    
                } else {
                    
                    // check if this is a border pixel
                    if isBorder(pixel: pixel, src: src) {
                        
                        // add this border pixel to the path
                        addPixelToPath(pixel: pixel)
                        
                        // next direction is clockwise from heading direction from currentPixel to new border pixel
                        let headingDirection = getHeading(from: currentPixel!, to: pixel)
                        let nextDirection = getNextClockwiseDirection(from: headingDirection!)
                        currentDirection = nextDirection
                        currentPixel = pixel
                        
                    } else {
                        
                        // next direction is clockwise from currentDirection
                        let nextDirection = getNextClockwiseDirection(from: currentDirection)
                        currentDirection = nextDirection
                        
                    }
                }
                
            } else {
                
                // No pixel found so maybe pixel location is beyond image
                // keep trying next direction clockwise from currentDirection
                let nextDirection = getNextClockwiseDirection(from: currentDirection)
                currentDirection = nextDirection
                
            }
            
        }
        
        // Close the path before returning
        path?.closeSubpath()
        
        return path
        
    }
    
}
