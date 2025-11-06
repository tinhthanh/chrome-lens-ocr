import express from 'express';
import multer from 'multer';
import cors from 'cors';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import Lens from './src/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const port = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// Serve static files
app.use(express.static('public'));

// Configure multer for file uploads
const storage = multer.memoryStorage();
const upload = multer({
    storage: storage,
    limits: {
        fileSize: 50 * 1024 * 1024 // 50MB limit
    }
});

// Initialize Lens
const lens = new Lens();

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({
        status: 'OK',
        service: 'Chrome Lens OCR API',
        version: '1.0.0',
        timestamp: new Date().toISOString()
    });
});

// API documentation endpoint
app.get('/api', (req, res) => {
    res.json({
        service: 'Chrome Lens OCR API',
        version: '1.0.0',
        endpoints: {
            'GET /health': 'Health check',
            'GET /api': 'API documentation',
            'POST /ocr/file': 'OCR from uploaded file',
            'POST /ocr/url': 'OCR from image URL',
            'POST /ocr/base64': 'OCR from base64 encoded image'
        },
        usage: {
            '/ocr/file': 'Upload image file using multipart/form-data with field name "image"',
            '/ocr/url': 'Send JSON with "url" field containing image URL',
            '/ocr/base64': 'Send JSON with "data" field containing base64 encoded image and optional "mime" field'
        }
    });
});

// OCR from uploaded file
app.post('/ocr/file', upload.single('image'), async (req, res) => {
    try {
        if (!req.file) {
            return res.status(400).json({
                error: 'No file uploaded',
                message: 'Please upload an image file using the "image" field'
            });
        }

        console.log(`Processing uploaded file: ${req.file.originalname}, size: ${req.file.size} bytes`);

        const result = await lens.scanByBuffer(req.file.buffer);

        res.json({
            success: true,
            data: result,
            metadata: {
                filename: req.file.originalname,
                size: req.file.size,
                mimetype: req.file.mimetype
            }
        });
    } catch (error) {
        console.error('Error processing file:', error);
        res.status(500).json({
            error: 'OCR processing failed',
            message: error.message,
            details: error.code || 'UNKNOWN_ERROR'
        });
    }
});

// OCR from URL
app.post('/ocr/url', async (req, res) => {
    try {
        const { url } = req.body;

        if (!url) {
            return res.status(400).json({
                error: 'Missing URL',
                message: 'Please provide a "url" field with the image URL'
            });
        }

        console.log(`Processing image from URL: ${url}`);

        const result = await lens.scanByURL(url);

        res.json({
            success: true,
            data: result,
            metadata: {
                url: url
            }
        });
    } catch (error) {
        console.error('Error processing URL:', error);
        res.status(500).json({
            error: 'OCR processing failed',
            message: error.message,
            details: error.code || 'UNKNOWN_ERROR'
        });
    }
});

// OCR from base64 data
app.post('/ocr/base64', async (req, res) => {
    try {
        const { data, mime } = req.body;

        if (!data) {
            return res.status(400).json({
                error: 'Missing data',
                message: 'Please provide a "data" field with base64 encoded image'
            });
        }

        console.log(`Processing base64 image, mime: ${mime || 'auto-detect'}`);

        // Remove data URL prefix if present
        const base64Data = data.replace(/^data:image\/[a-z]+;base64,/, '');
        const buffer = Buffer.from(base64Data, 'base64');

        const result = await lens.scanByBuffer(buffer);

        res.json({
            success: true,
            data: result,
            metadata: {
                size: buffer.length,
                mime: mime || 'auto-detected'
            }
        });
    } catch (error) {
        console.error('Error processing base64:', error);
        res.status(500).json({
            error: 'OCR processing failed',
            message: error.message,
            details: error.code || 'UNKNOWN_ERROR'
        });
    }
});

// Error handling middleware
app.use((error, req, res, next) => {
    console.error('Unhandled error:', error);
    res.status(500).json({
        error: 'Internal server error',
        message: error.message
    });
});

// 404 handler
app.use((req, res) => {
    res.status(404).json({
        error: 'Not found',
        message: `Endpoint ${req.method} ${req.path} not found`
    });
});

// Start server
app.listen(port, '0.0.0.0', () => {
    console.log(`Chrome Lens OCR API server running on port ${port}`);
    console.log(`Health check: http://localhost:${port}/health`);
    console.log(`API docs: http://localhost:${port}/api`);
    console.log(`Web UI: http://localhost:${port}/`);
});
