// Vercel serverless function entry point
// Wraps the Express app for serverless deployment
const app = require('../dashboard/server');

module.exports = app;
