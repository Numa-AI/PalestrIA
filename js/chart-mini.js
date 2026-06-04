// Mini chart library for simple visualizations
class SimpleChart {
    constructor(canvas, options = {}) {
        this.canvas = canvas;
        this.ctx = canvas.getContext('2d');
        const rect = canvas.getBoundingClientRect();
        const w = rect.width > 0 ? rect.width : (canvas.offsetWidth > 0 ? canvas.offsetWidth : 400);
        const h = options.height || 250;
        this.width = canvas.width = Math.round(w * 2);
        this.height = canvas.height = Math.round(h * 2);
        this.ctx.scale(2, 2);
    }

    drawLineChart(data, options = {}) {
        const padding = 40;
        const chartWidth = this.canvas.width / 2 - padding * 2;
        const chartHeight = this.canvas.height / 2 - padding * 2;

        // Clear canvas
        this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

        // Find max value
        const maxValue = Math.max(...data.values, 1);
        const points = [];

        // Calculate points
        const stepX = chartWidth / (data.labels.length - 1);
        data.values.forEach((value, i) => {
            const x = padding + i * stepX;
            const y = padding + chartHeight - (value / maxValue) * chartHeight;
            points.push({ x, y, value });
        });

        // Draw grid lines
        this.ctx.strokeStyle = '#e0e0e0';
        this.ctx.lineWidth = 1;
        for (let i = 0; i <= 5; i++) {
            const y = padding + (chartHeight / 5) * i;
            this.ctx.beginPath();
            this.ctx.moveTo(padding, y);
            this.ctx.lineTo(padding + chartWidth, y);
            this.ctx.stroke();
        }

        // Draw line
        this.ctx.strokeStyle = options.color || '#e63946';
        this.ctx.lineWidth = 3;
        this.ctx.beginPath();
        points.forEach((point, i) => {
            if (i === 0) {
                this.ctx.moveTo(point.x, point.y);
            } else {
                this.ctx.lineTo(point.x, point.y);
            }
        });
        this.ctx.stroke();

        // Draw points
        this.ctx.fillStyle = options.color || '#e63946';
        points.forEach(point => {
            this.ctx.beginPath();
            this.ctx.arc(point.x, point.y, 4, 0, Math.PI * 2);
            this.ctx.fill();
        });

        // Draw labels
        this.ctx.fillStyle = '#666';
        this.ctx.font = '11px sans-serif';
        this.ctx.textAlign = 'center';
        data.labels.forEach((label, i) => {
            const x = padding + i * stepX;
            this.ctx.fillText(label, x, this.canvas.height / 2 - 10);
        });

        // Draw values
        this.ctx.textAlign = 'left';
        for (let i = 0; i <= 5; i++) {
            const value = Math.round((maxValue / 5) * (5 - i));
            const y = padding + (chartHeight / 5) * i;
            this.ctx.fillText(value, 5, y + 4);
        }
    }

    drawBarChart(data, options = {}) {
        const ctx = this.ctx;
        const cw = this.canvas.width / 2;
        const ch = this.canvas.height / 2;
        ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

        const pad = { top: 24, right: 16, bottom: 44, left: 52 };
        const chartW = cw - pad.left - pad.right;
        const chartH = ch - pad.top - pad.bottom;
        const n = data.values.length;

        if (n === 0) {
            ctx.fillStyle = '#9ca3af';
            ctx.font = '13px sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText('Nessun dato', cw / 2, ch / 2);
            return;
        }

        const maxVal = Math.max(...data.values.map((v, i) => {
            const base = Array.isArray(v) ? Math.max(...v) : v;
            return base + ((data.projected && data.projected[i]) || 0) + ((data.estimated && data.estimated[i]) || 0);
        }), 1);
        const step = Math.ceil(maxVal / 5) || 1;
        const axisMax = step * 5;

        // Grid + Y labels
        ctx.strokeStyle = '#e5e7eb';
        ctx.lineWidth = 1;
        ctx.fillStyle = '#9ca3af';
        ctx.font = '10px sans-serif';
        ctx.textAlign = 'right';
        for (let i = 0; i <= 5; i++) {
            const y = pad.top + chartH - (chartH * i / 5);
            ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(pad.left + chartW, y); ctx.stroke();
            ctx.fillText(`${options.prefix ?? '€'}${Math.round(axisMax * i / 5)}${options.suffix ?? ''}`, pad.left - 5, y + 4);
        }

        const slotW = chartW / n;
        const seriesCount = Array.isArray(data.values[0]) ? data.values[0].length : 1;
        const barW = Math.min(slotW * 0.7 / seriesCount, 40);
        const colors = options.colors || ['#3b82f6', '#94a3b8'];

        data.values.forEach((val, i) => {
            const vals = Array.isArray(val) ? val : [val];
            const totalBarsW = barW * seriesCount + (seriesCount - 1) * 3;
            const slotStart = pad.left + i * slotW + (slotW - totalBarsW) / 2;

            vals.forEach((v, s) => {
                const barH = (v / axisMax) * chartH;
                const x = slotStart + s * (barW + 3);
                const y = pad.top + chartH - barH;
                ctx.fillStyle = colors[s % colors.length];
                ctx.beginPath();
                if (ctx.roundRect) ctx.roundRect(x, y, barW, barH, [3, 3, 0, 0]);
                else ctx.rect(x, y, barW, barH);
                ctx.fill();
                if (v > 0) {
                    ctx.fillStyle = '#333';
                    ctx.textAlign = 'center';
                    ctx.font = 'bold 9px sans-serif';
                    const label = data.valueLabels?.[i]?.[0] || `${options.prefix ?? '€'}${v}${options.suffix ?? ''}`;
                    ctx.fillText(label, x + barW / 2, y - 4);
                }
            });

            // Projected extension on top (single-series only)
            if (data.projected && data.projected[i] > 0 && seriesCount === 1) {
                const projH  = (data.projected[i] / axisMax) * chartH;
                const solidH = (vals[0] / axisMax) * chartH;
                const px = slotStart;
                const py = pad.top + chartH - solidH - projH;
                ctx.save();
                ctx.globalAlpha = 0.28;
                ctx.fillStyle = '#e63946';
                ctx.beginPath();
                if (ctx.roundRect) ctx.roundRect(px, py, barW, projH, [3, 3, 0, 0]);
                else ctx.rect(px, py, barW, projH);
                ctx.fill();
                ctx.globalAlpha = 1;
                ctx.strokeStyle = '#e63946';
                ctx.lineWidth = 1.5;
                ctx.setLineDash([3, 2]);
                ctx.beginPath();
                if (ctx.roundRect) ctx.roundRect(px, py, barW, projH, [3, 3, 0, 0]);
                else ctx.rect(px, py, barW, projH);
                ctx.stroke();
                ctx.setLineDash([]);
                ctx.restore();
            }

            // Estimated extension on top (green dashed, single-series only)
            if (data.estimated && data.estimated[i] > 0 && seriesCount === 1) {
                const estH   = (data.estimated[i] / axisMax) * chartH;
                const solidH = (vals[0] / axisMax) * chartH;
                const projH  = data.projected?.[i] ? (data.projected[i] / axisMax) * chartH : 0;
                const px = slotStart;
                const py = pad.top + chartH - solidH - projH - estH;
                ctx.save();
                ctx.globalAlpha = 0.22;
                ctx.fillStyle = '#22c55e';
                ctx.beginPath();
                if (ctx.roundRect) ctx.roundRect(px, py, barW, estH, [3, 3, 0, 0]);
                else ctx.rect(px, py, barW, estH);
                ctx.fill();
                ctx.globalAlpha = 1;
                ctx.strokeStyle = '#22c55e';
                ctx.lineWidth = 1.5;
                ctx.setLineDash([3, 2]);
                ctx.beginPath();
                if (ctx.roundRect) ctx.roundRect(px, py, barW, estH, [3, 3, 0, 0]);
                else ctx.rect(px, py, barW, estH);
                ctx.stroke();
                ctx.setLineDash([]);
                ctx.restore();
            }

            // X label
            ctx.fillStyle = data.highlight?.[i] ? '#e63946' : '#6b7280';
            ctx.font = data.highlight?.[i] ? 'bold 10px sans-serif' : '10px sans-serif';
            ctx.textAlign = 'center';
            const labelX = pad.left + i * slotW + slotW / 2;
            ctx.fillText(data.labels[i], labelX, ch - pad.bottom / 3 + 4);
        });

        // Legend
        if (options.legend) {
            let lx = pad.left;
            options.legend.forEach((l, i) => {
                ctx.fillStyle = colors[i % colors.length];
                ctx.fillRect(lx, pad.top - 16, 10, 10);
                ctx.fillStyle = '#6b7280';
                ctx.font = '10px sans-serif';
                ctx.textAlign = 'left';
                ctx.fillText(l, lx + 14, pad.top - 7);
                lx += ctx.measureText(l).width + 30;
            });
        }
    }

    drawForecastChart(data, options = {}) {
        // data: { actual: [...], forecast: [...], labels: [...], todayIndex: N }
        const ctx = this.ctx;
        const cw = this.canvas.width / 2;
        const ch = this.canvas.height / 2;
        ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

        const pad = { top: 24, right: 16, bottom: 40, left: 52 };
        const chartW = cw - pad.left - pad.right;
        const chartH = ch - pad.top - pad.bottom;
        const n = data.labels.length;
        if (n === 0) return;

        const allVals = [...(data.actual || []), ...(data.forecast || []), ...(data.estimated || [])];
        const maxVal = Math.max(...allVals.filter(v => v != null), 1);
        const step = Math.ceil(maxVal / 5) || 1;
        const axisMax = step * 5;

        // Grid + Y labels
        ctx.strokeStyle = '#e5e7eb'; ctx.lineWidth = 1;
        ctx.fillStyle = '#9ca3af'; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
        for (let i = 0; i <= 5; i++) {
            const y = pad.top + chartH - (chartH * i / 5);
            ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(pad.left + chartW, y); ctx.stroke();
            ctx.fillText(`€${Math.round(axisMax * i / 5)}`, pad.left - 5, y + 4);
        }

        const stepX = chartW / (n - 1 || 1);
        const pt = (vals, i) => ({ x: pad.left + i * stepX, y: pad.top + chartH - (vals[i] / axisMax) * chartH });

        const drawLine = (vals, color, dashed = false) => {
            if (!vals || vals.length === 0) return;
            ctx.strokeStyle = color; ctx.lineWidth = 2.5;
            ctx.setLineDash(dashed ? [6, 4] : []);
            ctx.beginPath();
            vals.forEach((v, i) => {
                if (v === null || v === undefined) return;
                const p = pt(vals, i);
                i === 0 || vals[i - 1] == null ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y);
            });
            ctx.stroke();
            ctx.setLineDash([]);
            ctx.fillStyle = color;
            vals.forEach((v, i) => {
                if (v == null) return;
                const p = pt(vals, i);
                ctx.beginPath(); ctx.arc(p.x, p.y, 3.5, 0, Math.PI * 2); ctx.fill();
            });
        };

        // Today line
        if (data.todayIndex != null) {
            const tx = pad.left + data.todayIndex * stepX;
            ctx.strokeStyle = '#e63946'; ctx.lineWidth = 1.5;
            ctx.setLineDash([4, 3]);
            ctx.beginPath(); ctx.moveTo(tx, pad.top); ctx.lineTo(tx, pad.top + chartH); ctx.stroke();
            ctx.setLineDash([]);
            ctx.fillStyle = '#e63946'; ctx.font = 'bold 9px sans-serif'; ctx.textAlign = 'left';
            ctx.fillText('Oggi', tx + 4, pad.top + 12);
        }

        drawLine(data.actual, '#3b82f6', false);
        drawLine(data.forecast, '#94a3b8', true);
        drawLine(data.estimated, '#22c55e', true);

        // X labels (thin out if too many)
        const skip = Math.ceil(n / 8);
        ctx.fillStyle = '#6b7280'; ctx.font = '10px sans-serif'; ctx.textAlign = 'center';
        data.labels.forEach((l, i) => {
            if (i % skip !== 0 && i !== n - 1) return;
            ctx.fillText(l, pad.left + i * stepX, ch - 6);
        });

        // Legend
        const legendItems = [
            { color: '#3b82f6', label: 'Effettivo' },
            { color: '#94a3b8', label: 'Confermato', dashed: true },
            ...(data.estimated?.some(v => v != null) ? [{ color: '#22c55e', label: 'Stima', dashed: true }] : [])
        ];
        let lx = pad.left;
        legendItems.forEach(item => {
            if (item.dashed) { ctx.setLineDash([5, 3]); }
            ctx.strokeStyle = item.color; ctx.lineWidth = 2;
            ctx.beginPath(); ctx.moveTo(lx, pad.top - 10); ctx.lineTo(lx + 16, pad.top - 10); ctx.stroke();
            ctx.setLineDash([]);
            ctx.fillStyle = '#6b7280'; ctx.font = '10px sans-serif'; ctx.textAlign = 'left';
            ctx.fillText(item.label, lx + 20, pad.top - 6);
            lx += 70;
        });
    }

    drawPieChart(data, options = {}) {
        const ctx = this.ctx;
        const cw = this.canvas.width / 2;   // logical width
        const ch = this.canvas.height / 2;  // logical height
        ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

        const colors = options.colors || ['#ff6b6b', '#4ecdc4', '#ffd93d'];
        const total = data.values.reduce((a, b) => a + b, 0);

        if (total === 0) {
            ctx.fillStyle = '#ccc';
            ctx.font = '14px sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText('Nessun dato', cw / 2, ch / 2);
            return;
        }

        // Layout: mobile = chart top + legend bottom; desktop = chart left + legend right
        const isMobile = options.mobile || false;
        const legendItemH = 22;
        const legendH = data.labels.length * legendItemH + 8;
        const chartAreaH = isMobile ? ch - legendH : ch;
        const chartAreaW = isMobile ? cw : cw * 0.55;

        const centerX = chartAreaW / 2;
        const centerY = chartAreaH / 2;
        const radius = Math.min(centerX, chartAreaH / 2) - 24;
        const innerRadius = radius * 0.52;

        if (radius <= 0) return;

        // ── Draw donut slices ──
        let currentAngle = -Math.PI / 2;
        data.values.forEach((value, i) => {
            const sliceAngle = (value / total) * Math.PI * 2;
            ctx.fillStyle = colors[i % colors.length];
            ctx.beginPath();
            ctx.moveTo(centerX + innerRadius * Math.cos(currentAngle), centerY + innerRadius * Math.sin(currentAngle));
            ctx.arc(centerX, centerY, radius, currentAngle, currentAngle + sliceAngle);
            ctx.arc(centerX, centerY, innerRadius, currentAngle + sliceAngle, currentAngle, true);
            ctx.closePath();
            ctx.fill();
            ctx.strokeStyle = '#fff';
            ctx.lineWidth = 2;
            ctx.stroke();

            // ── % label on slice ──
            const midAngle = currentAngle + sliceAngle / 2;
            const labelR = (radius + innerRadius) / 2;
            const lx = centerX + labelR * Math.cos(midAngle);
            const ly = centerY + labelR * Math.sin(midAngle);
            const pct = Math.round((value / total) * 100);
            if (pct >= 8) {
                ctx.fillStyle = '#fff';
                ctx.font = 'bold 11px sans-serif';
                ctx.textAlign = 'center';
                ctx.textBaseline = 'middle';
                ctx.fillText(`${pct}%`, lx, ly);
            }

            currentAngle += sliceAngle;
        });

        // ── Total in center ──
        ctx.fillStyle = '#333';
        ctx.font = 'bold 16px sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        const piePrefix = options.prefix ?? '€';
        ctx.fillText(`${piePrefix}${total}`, centerX, centerY - 6);
        ctx.fillStyle = '#888';
        ctx.font = '10px sans-serif';
        ctx.fillText('Totale', centerX, centerY + 10);

        // ── Legend ──
        ctx.textBaseline = 'alphabetic';
        let lx, ly;
        if (isMobile) {
            // Legend below chart, centered
            lx = 12;
            ly = chartAreaH + 8;
        } else {
            // Legend right of chart
            lx = chartAreaW + 16;
            ly = centerY - (data.labels.length * legendItemH) / 2;
        }

        ctx.textAlign = 'left';
        data.labels.forEach((label, i) => {
            ctx.fillStyle = colors[i % colors.length];
            ctx.fillRect(lx, ly, 10, 10);
            ctx.fillStyle = '#333';
            ctx.font = '11px sans-serif';
            const pct = Math.round((data.values[i] / total) * 100);
            const valPrefix = options.prefix ?? '€';
            ctx.fillText(`${label} — ${valPrefix}${data.values[i]} (${pct}%)`, lx + 14, ly + 9);
            ly += legendItemH;
        });
    }
}
