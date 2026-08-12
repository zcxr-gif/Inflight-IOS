export class PerformanceMonitor {
    // Set this flag to true when you want to show the monitor on the screen again.
    // Leaving it false prevents the DOM elements from rendering and stops the background loop.
    static showUI = false;

    static init() {
        if (!this.showUI) return;
        if (document.getElementById('perf-monitor-ui')) return;

        // Construct the UI container
        const container = document.createElement('div');
        container.id = 'perf-monitor-ui';
        Object.assign(container.style, {
            position: 'fixed',
            bottom: '20px',
            left: '20px',
            backgroundColor: 'rgba(15, 23, 42, 0.9)',
            color: '#4ade80',
            fontFamily: 'monospace',
            fontSize: '13px',
            padding: '12px',
            borderRadius: '8px',
            border: '1px solid #334155',
            zIndex: '99999',
            pointerEvents: 'none',
            minWidth: '200px',
            boxShadow: '0 4px 6px rgba(0,0,0,0.3)'
        });

        // Create data display nodes
        const headerDiv = document.createElement('div');
        headerDiv.textContent = 'SYSTEM PERFORMANCE';
        headerDiv.style.fontWeight = 'bold';
        headerDiv.style.borderBottom = '1px solid #334155';
        headerDiv.style.paddingBottom = '5px';
        headerDiv.style.marginBottom = '5px';
        headerDiv.style.color = '#ffffff';

        const fpsDiv = document.createElement('div');
        const memDiv = document.createElement('div');
        const domDiv = document.createElement('div');
        
        const customHeader = document.createElement('div');
        customHeader.textContent = 'FUNCTION TIMINGS';
        customHeader.style.fontWeight = 'bold';
        customHeader.style.borderBottom = '1px solid #334155';
        customHeader.style.paddingBottom = '5px';
        customHeader.style.marginTop = '10px';
        customHeader.style.marginBottom = '5px';
        customHeader.style.color = '#ffffff';

        const customDiv = document.createElement('div');
        customDiv.id = 'perf-custom-metrics';

        // Assemble the UI
        container.appendChild(headerDiv);
        container.appendChild(fpsDiv);
        container.appendChild(memDiv);
        container.appendChild(domDiv);
        container.appendChild(customHeader);
        container.appendChild(customDiv);
        document.body.appendChild(container);

        // Tracking variables
        let frames = 0;
        let lastTime = performance.now();

        // The render loop
        const loop = () => {
            frames++;
            const now = performance.now();
            
            // Update UI every 1000ms (1 second)
            if (now >= lastTime + 1000) {
                const currentFps = Math.round((frames * 1000) / (now - lastTime));
                
                // Color code FPS
                if (currentFps >= 55) {
                    fpsDiv.style.color = '#4ade80'; // Green
                } else if (currentFps >= 30) {
                    fpsDiv.style.color = '#fbbf24'; // Yellow
                } else {
                    fpsDiv.style.color = '#ef4444'; // Red
                }
                
                fpsDiv.textContent = `FPS: ${currentFps}`;
                frames = 0;
                lastTime = now;

                // Track Memory (Supported in Chromium-based browsers)
                if (performance.memory) {
                    const usedJSHeapSize = (performance.memory.usedJSHeapSize / (1024 * 1024)).toFixed(1);
                    const jsHeapSizeLimit = (performance.memory.jsHeapSizeLimit / (1024 * 1024)).toFixed(1);
                    memDiv.textContent = `Memory: ${usedJSHeapSize} MB / ${jsHeapSizeLimit} MB`;
                } else {
                    memDiv.textContent = `Memory: API not supported`;
                }

                // Track DOM Size
                domDiv.textContent = `DOM Nodes: ${document.getElementsByTagName('*').length}`;
            }
            requestAnimationFrame(loop);
        };
        
        requestAnimationFrame(loop);
    }

    /**
     * Wraps an asynchronous function to measure its exact execution time.
     * @param {string} name - The label to display in the UI and console.
     * @param {Function} fn - The asynchronous function to execute.
     */
    static async measureAsync(name, fn) {
        const start = performance.now();
        const result = await fn();
        const end = performance.now();
        const duration = (end - start).toFixed(2);

        // Update visual overlay only if the UI is enabled
        if (this.showUI) {
            const customDiv = document.getElementById('perf-custom-metrics');
            if (customDiv) {
                let metric = document.getElementById(`metric-${name.replace(/\s+/g, '-')}`);
                if (!metric) {
                    metric = document.createElement('div');
                    metric.id = `metric-${name.replace(/\s+/g, '-')}`;
                    customDiv.appendChild(metric);
                }
                metric.textContent = `${name}: ${duration}ms`;
                
                // Highlight slow functions (> 500ms)
                if (parseFloat(duration) > 500) {
                    metric.style.color = '#fbbf24';
                }
            }
        }
        
        // Log to console for persistent history regardless of UI state
        console.info(`[Performance] ${name} completed in ${duration}ms`);
        return result;
    }
}