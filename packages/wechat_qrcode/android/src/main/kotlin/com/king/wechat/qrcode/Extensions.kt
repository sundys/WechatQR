package com.king.wechat.qrcode

import org.opencv.core.Mat
import org.opencv.core.Point

/**
 * 扩展函数：将检测结果点 [Mat]列表转换为二维码顶点 [Point] 列表；（适用于：WeChatQRCodeDetector）
 *
 * @author <a href="mailto:jenly1314@gmail.com">Jenly</a>
 * <p>
 * <a href="https://github.com/jenly1314">Follow me</a>
 */
fun List<Mat>.toVertexPoints(): List<Point> {
    val points = mutableListOf<Point>()
    this.forEach { mat ->
        val rows = mat.rows()
        for (i in 0 until rows) {
            val x = mat[i, 0][0]
            val y = mat[i, 1][0]
            points.add(Point(x, y))
        }
    }
    return points
}
